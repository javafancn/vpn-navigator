import Foundation
import Darwin

/// One atomic publication for both address families. Legacy text caches are
/// read only until the first successful publication. The advisory lock also
/// serializes the app and the user-scoped background agent.
enum RuleCacheStore {
    struct Snapshot: Codable {
        var schemaVersion = 1
        var ipv4: String?
        var ipv6: String?
        var ipv4UpdatedAt: Date?
        var bundle: String? { ipv4.map { RoutingRuleBundle(ipv4: $0, ipv6: ipv6).json } }
    }
    static func read(_ root: URL) throws -> Snapshot {
        let file = root.appendingPathComponent("routing-rules.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let value = try JSONDecoder().decode(Snapshot.self, from: ProfileFileIO.read(file, maximumBytes: 5_000_000))
            guard value.schemaVersion == 1 else { throw RuleError.suspiciousChange }
            if let text = value.ipv4 { _ = try RuleSet(text: text) }
            if let text = value.ipv6 { _ = try IPv6RuleSet(text: text) }
            return value
        }
        func legacy(_ name: String) throws -> String? {
            let path = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return String(decoding: try ProfileFileIO.read(path), as: UTF8.self)
        }
        let date = try? root.appendingPathComponent("china-ipv4.txt").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return try Snapshot(ipv4: legacy("china-ipv4.txt"), ipv6: legacy("china-ipv6-preview.txt"), ipv4UpdatedAt: date)
    }
    final class Prepared {
        let previous: Snapshot
        let next: Snapshot
        private let root: URL
        private let staged: URL
        private let descriptor: Int32
        private let archived: URL?
        private var published = false
        init(root: URL, ipv4: RuleSet?, ipv6: IPv6RuleSet?) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let lock = open(root.appendingPathComponent("routing-rules.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard lock >= 0 else { throw ProfileFileIO.Failure.cannotWrite }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw RuleCacheFailure.busy }
            do {
                // A terminated writer may leave an unpublished, private stage.
                // No other writer can own one while this lock is held.
                for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    let prefix = ".routing-rules-"
                    if file.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(file.lastPathComponent.dropFirst(prefix.count))) != nil {
                        try FileManager.default.removeItem(at: file)
                    }
                }
                let old = try RuleCacheStore.read(root)
                if let ipv4, let text = old.ipv4 { try RuleUpdater.validateChange(previous: RuleSet(text: text), next: ipv4) }
                if let ipv6 {
                    guard ipv6.routes.count >= 100 else { throw APNICIPv6Error.missingCountryData }
                    if let text = old.ipv6 { try IPv6RuleSet.validateChange(previous: IPv6RuleSet(text: text), next: ipv6) }
                }
                var value = old
                if let ipv4 {
                    value.ipv4 = ipv4.routes.map(\.description).joined(separator: "\n") + "\n"
                    if value.ipv4 != old.ipv4 { value.ipv4UpdatedAt = Date() }
                }
                if let ipv6 { value.ipv6 = ipv6.routes.map(\.description).joined(separator: "\n") + "\n" }
                let stage = root.appendingPathComponent(".routing-rules-" + UUID().uuidString)
                try ProfileFileIO.write(JSONEncoder().encode(value), to: stage)
                var archived: URL?
                do {
                    if old.ipv4 != value.ipv4, let text = old.ipv4 {
                        let archive = root.appendingPathComponent("Snapshots", isDirectory: true)
                        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let file = archive.appendingPathComponent(UUID().uuidString + ".txt")
                        try ProfileFileIO.write(Data(text.utf8), to: file)
                        archived = file
                    }
                } catch { try? FileManager.default.removeItem(at: stage); throw error }
                self.root = root; staged = stage; previous = old; next = value; descriptor = lock; self.archived = archived
            } catch { flock(lock, LOCK_UN); close(lock); throw error }
        }
        func publish() throws {
            let destination = root.appendingPathComponent("routing-rules.json")
            // All content was already validated and fsynced before a live
            // route update. One rename is the cache's commit point.
            guard rename(staged.path, destination.path) == 0 else { throw ProfileFileIO.Failure.cannotWrite }
            published = true
            let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if directory >= 0 { _ = fsync(directory); close(directory) }
            let archive = root.appendingPathComponent("Snapshots")
            if let files = try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: [.contentModificationDateKey]) {
                let snapshots = files.filter { $0.pathExtension == "txt" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
                    .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for file in snapshots.dropFirst(10) { try? FileManager.default.removeItem(at: file) }
            }
        }
        deinit {
            try? FileManager.default.removeItem(at: staged)
            if !published, let archived { try? FileManager.default.removeItem(at: archived) }
            flock(descriptor, LOCK_UN); close(descriptor)
        }
    }
}

public enum RuleCacheFailure: Error, LocalizedError {
    case busy, helperRejected(String), rollbackFailed
    public var errorDescription: String? {
        switch self {
        case .busy: return L10n.text("另一个规则更新正在进行，请稍后重试。")
        case .helperRejected(let response): return L10n.format("助手未确认规则更新：{0}", [response])
        case .rollbackFailed: return L10n.text("规则缓存未发布，助手恢复旧规则未获确认。请断开 VPN 并重新连接以同步规则。")
        }
    }
}

public enum RoutingRuleUpdate {
    public struct Cached: Sendable {
        public let ipv4: RuleSet?
        public let ipv6: IPv6RuleSet?
        public let ipv4UpdatedAt: Date?
    }
    public static func cached(root: URL) async throws -> Cached {
        let snapshot = try RuleCacheStore.read(root)
        return try Cached(ipv4: snapshot.ipv4.map { try RuleSet(text: $0) },
                          ipv6: snapshot.ipv6.map { try IPv6RuleSet(text: $0) }, ipv4UpdatedAt: snapshot.ipv4UpdatedAt)
    }
    /// The callback returns the helper's typed acknowledgement, or NO_ACTIVE_SPLIT
    /// when no live split session needs changing. It is also used for compensation.
    public static func commit(root: URL, ipv4: RuleSet? = nil, ipv6: IPv6RuleSet? = nil,
                              apply: (String) async -> String) async throws {
        let prepared = try RuleCacheStore.Prepared(root: root, ipv4: ipv4, ipv6: ipv6)
        guard let bundle = prepared.next.bundle else { throw RuleError.empty }
        try Task.checkCancellation()
        let response = await apply(bundle)
        guard response == "Rules applied" || response == "NO_ACTIVE_SPLIT" else { throw RuleCacheFailure.helperRejected(response) }
        // Once the helper acknowledges, finish publication even if the caller
        // cancels. Otherwise cancellation could split the two states.
        do { try prepared.publish() }
        catch {
            if response == "Rules applied" {
                guard let previous = prepared.previous.bundle else { throw RuleCacheFailure.rollbackFailed }
                let rollback = await apply(previous)
                guard rollback == "Rules applied" || rollback == "NO_ACTIVE_SPLIT" else { throw RuleCacheFailure.rollbackFailed }
            }
            throw error
        }
    }
}
