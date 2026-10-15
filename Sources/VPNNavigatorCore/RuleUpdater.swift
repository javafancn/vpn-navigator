import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads and validates a rule snapshot. No system routes are changed here.
public actor RuleUpdater {
    public static let source = URL(string: "https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt")!
    private let folder: URL
    public init(folder: URL) { self.folder = folder }
    public func cached() throws -> RuleSet? {
        let file = folder.appendingPathComponent("china-ipv4.txt")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try RuleSet(text: String(contentsOf: file, encoding: .utf8))
    }
    public func refresh() async throws -> RuleSet {
        let (data, response) = try await URLSession.shared.data(from: Self.source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RuleError.empty }
        guard data.count > 1000, data.count < 2_000_000,
              let content = String(data: data, encoding: .utf8) else { throw RuleError.tooLarge }
        let validated = try RuleSet(text: content)
        // Fail closed on unexpectedly small feeds; never destroy previously cached rules.
        guard validated.routes.count >= 100 else { throw RuleError.empty }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("china-ipv4.txt"), options: .atomic)
        return validated
    }
}
