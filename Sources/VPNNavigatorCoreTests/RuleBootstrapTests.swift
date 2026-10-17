import XCTest
@testable import VPNNavigatorCore

final class RuleBootstrapTests: XCTestCase {
    func testOfflineBootstrapDoesNotReplaceExistingRules() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed.txt")
        let text = (0..<100).map { "223.5.\($0).0/24" }.joined(separator: "\n")
        try text.write(to: seed, atomically: true, encoding: .utf8)
        let updater = RuleUpdater(folder: root.appendingPathComponent("cache"))
        let first = try await updater.bootstrap(seed)
        XCTAssertEqual(first.routes.count, 100)
        let updated = try await updater.lastUpdated()
        XCTAssertNotNil(updated)
        try "invalid replacement".write(to: seed, atomically: true, encoding: .utf8)
        let existing = try await updater.bootstrap(seed)
        XCTAssertEqual(existing.routes, first.routes)
        let cached = try await updater.cached()
        XCTAssertEqual(cached?.routes, first.routes)
    }
    func testInvalidOfflineImportPreservesCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("invalid.txt")
        try "0.0.0.0/0".write(to: invalid, atomically: true, encoding: .utf8)
        let updater = RuleUpdater(folder: root.appendingPathComponent("cache"))
        do { _ = try await updater.localCandidate(invalid); XCTFail("Unsafe rules were accepted") }
        catch { }
        let cached = try await updater.cached()
        XCTAssertNil(cached)
    }
}
