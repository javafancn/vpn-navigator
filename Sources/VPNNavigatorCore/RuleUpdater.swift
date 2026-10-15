import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RuleSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let savedAt: Date
    public let routeCount: Int
}

/// Atomic, validated country IPv4 snapshot manager. No root permissions required.
public actor RuleUpdater {
    public static let source = URL(string: "https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt")!
    private let folder: URL
    private var archive: URL { folder.appendingPathComponent("Snapshots", isDirectory: true) }
    public init(folder: URL) { self.folder = folder }

    public func snapshots() throws -> [RuleSnapshot] {
        guard FileManager.default.fileExists(atPath: archive.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: archive, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]).compactMap { file in
                guard file.pathExtension == "txt",
                      let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      let ruleSet = try? RuleSet(text: String(contentsOf: file, encoding: .utf8))
                else { return nil }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date.distantPast
                return RuleSnapshot(id: id, savedAt: date, routeCount: ruleSet.routes.count)
            }.sorted { $0.savedAt > $1.savedAt }
    }

    public func archivedRules(id: UUID) throws -> RuleSet {
        let file = archive.appendingPathComponent(id.uuidString + ".txt")
        return try RuleSet(text: String(contentsOf: file, encoding: .utf8))
    }

    private func archivePrevious(_ previous: RuleSet) throws {
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archive.path)
        let snapshot = archive.appendingPathComponent(UUID().uuidString + ".txt")
        try Self.serialize(previous).write(to: snapshot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
    }

    private func pruneArchives(keeping count: Int = 10) {
        guard let old = try? snapshots() else { return }
        for item in old.dropFirst(count) {
            try? FileManager.default.removeItem(at:
                archive.appendingPathComponent(item.id.uuidString + ".txt"))
        }
    }

    private static func serialize(_ rules: RuleSet) -> String {
        rules.routes.map(\.description).joined(separator: "\n") + "\n"
    }
    public func cached() throws -> RuleSet? {
        let file = folder.appendingPathComponent("china-ipv4.txt")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try RuleSet(text: String(contentsOf: file, encoding: .utf8))
    }
    public func fetchCandidate() async throws -> RuleSet {
        let (data, response) = try await URLSession.shared.data(from: Self.source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RuleError.empty }
        guard data.count > 1000, data.count < 2_000_000,
              let content = String(data: data, encoding: .utf8) else { throw RuleError.tooLarge }
        let validated = try RuleSet(text: content)
        guard validated.routes.count >= 100 else { throw RuleError.empty }
        if let previous = try cached() { try Self.validateChange(previous: previous, next: validated) }
        return validated
    }
    public func commit(_ value: RuleSet) throws {
        if let previous = try cached() {
            try Self.validateChange(previous: previous, next: value)
            guard previous.routes != value.routes else { return }
            try archivePrevious(previous)
        }
        try save(value)
        pruneArchives()
    }
    public static func validateChange(previous: RuleSet, next: RuleSet) throws {
        guard previous.routes.count > 0 else { throw RuleError.empty }
        let old = previous.routes.count, current = next.routes.count
        // Country route lists usually change incrementally. Reject abrupt
        // feed corruption or hijacks without replacing the last known-good copy.
        guard current >= old * 85 / 100, current <= old * 115 / 100 else {
            throw RuleError.suspiciousChange
        }
        let delta = next.diff(from: previous)
        guard delta.added.count + delta.removed.count <= max(100, old / 3) else {
            throw RuleError.suspiciousChange
        }
    }
    private func save(_ value: RuleSet) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let target = folder.appendingPathComponent("china-ipv4.txt")
        let encoded = Self.serialize(value)
        try encoded.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    public func refresh() async throws -> RuleSet {
        let candidate = try await fetchCandidate()
        try commit(candidate)
        return candidate
    }
}
