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

    public func cached() throws -> RuleSet? {
        try RuleCacheStore.read(folder).ipv4.map { try RuleSet(text: $0) }
    }
    public func localCandidate(_ url: URL) throws -> RuleSet {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) < 2_000_000 else { throw RuleError.tooLarge }
        let value = try RuleSet(text: String(contentsOf: url, encoding: .utf8))
        guard value.routes.count >= 100 else { throw RuleError.empty }
        if let previous = try cached() { try Self.validateChange(previous: previous, next: value) }
        return value
    }
    public func bootstrap(_ url: URL) throws -> RuleSet {
        if let existing = try cached() { return existing }
        let candidate = try localCandidate(url)
        try commit(candidate)
        return candidate
    }
    public func lastUpdated() throws -> Date? { try RuleCacheStore.read(folder).ipv4UpdatedAt }
    public func fetchCandidate() async throws -> RuleSet {
        let sources = [Self.source, URL(string: "https://api.github.com/repos/misakaio/chnroutes2/contents/chnroutes.txt?ref=master")!]
        var failure: Error = RuleError.empty
        for source in sources {
            do {
                let data = try await RuleFeedRequest.fetch(source)
                guard data.count > 1000, let text = String(data: data, encoding: .utf8) else { throw RuleError.empty }
                let validated = try RuleSet(text: text)
                guard validated.routes.count >= 100 else { throw RuleError.empty }
                if let previous = try cached() { try Self.validateChange(previous: previous, next: validated) }
                return validated
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        throw failure
    }
    public func commit(_ value: RuleSet) throws {
        let prepared = try RuleCacheStore.Prepared(root: folder, ipv4: value, ipv6: nil)
        try prepared.publish()
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
    public func refresh() async throws -> RuleSet {
        let candidate = try await fetchCandidate()
        try commit(candidate)
        return candidate
    }
}

