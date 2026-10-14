import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Atomic, validated country IPv4 snapshot manager. No root permissions required.
public actor RuleUpdater {
    public static let source = URL(string: "https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt")!
    private let folder: URL
    public init(folder: URL) { self.folder = folder }
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
        return validated
    }
    public func commit(_ value: RuleSet) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let target = folder.appendingPathComponent("china-ipv4.txt")
        let encoded = value.routes.map(\.description).joined(separator: "\n") + "\n"
        try encoded.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    public func refresh() async throws -> RuleSet {
        let candidate = try await fetchCandidate()
        try commit(candidate)
        return candidate
    }
}
