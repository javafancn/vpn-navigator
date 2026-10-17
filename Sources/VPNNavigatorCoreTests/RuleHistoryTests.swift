import XCTest
@testable import VPNNavigatorCore

final class RuleHistoryTests: XCTestCase {
    func testSnapshotsRecordLastGoodVersionsAndCanBeLoaded() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vn-rules-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RuleUpdater(folder: folder)
        let first = try RuleSet(text: "223.5.5.0/24\n1.0.1.0/24")
        let second = try RuleSet(text: "223.5.5.0/24\n1.0.2.0/24")
        try await store.commit(first)
        let before = try await store.snapshots()
        XCTAssertEqual(before.count, 0)
        try await store.commit(second)
        let history = try await store.snapshots()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].routeCount, 2)
        let archived = try await store.archivedRules(id: history[0].id)
        XCTAssertTrue(archived.contains(ip: "1.0.1.2"))
        XCTAssertFalse(archived.contains(ip: "1.0.2.2"))
        let current = try await store.cached()
        XCTAssertEqual(current?.routes, second.routes)
        try await store.commit(second)
        let unchanged = try await store.snapshots()
        XCTAssertEqual(unchanged.count, 1)
    }
    func testRejectFakeSnapshotUUID() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vn-empty-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RuleUpdater(folder: folder)
        do {
            _ = try await store.archivedRules(id: UUID())
            XCTFail("Invalid snapshot should be refused")
        } catch {}
    }
}
