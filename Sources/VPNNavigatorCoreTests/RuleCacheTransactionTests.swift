import XCTest
@testable import VPNNavigatorCore

final class RuleCacheTransactionTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func rules4(_ start: Int) throws -> RuleSet { try RuleSet(text: (start..<(start + 100)).map { "11.0.\($0).0/24" }.joined(separator: "\n")) }
    private func rules6(_ start: Int) throws -> IPv6RuleSet { try IPv6RuleSet(text: (start..<(start + 100)).map { "2400:100:\(String($0, radix: 16))::/48" }.joined(separator: "\n")) }
    func testRejectsBothBeforeApplyingWhenIPv6ChangeIsSuspicious() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let old4 = try rules4(0), old6 = try rules6(0)
        try await RoutingRuleUpdate.commit(root: folder, ipv4: old4, ipv6: old6) { _ in "NO_ACTIVE_SPLIT" }
        var called = false
        do {
            try await RoutingRuleUpdate.commit(root: folder, ipv4: rules4(1), ipv6: rules6(100)) { _ in called = true; return "Rules applied" }
            XCTFail("Suspicious IPv6 data accepted")
        } catch RuleError.suspiciousChange {}
        XCTAssertFalse(called)
        let saved4 = try await RuleUpdater(folder: folder).cached(), saved6 = try await APNICIPv6PreviewStore(root: folder).cached()
        XCTAssertEqual(saved4?.routes, old4.routes); XCTAssertEqual(saved6?.routes, old6.routes)
    }
    func testHelperRejectionPreservesBothAndConcurrentMutationIsRefused() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let old4 = try rules4(0), old6 = try rules6(0)
        try await RoutingRuleUpdate.commit(root: folder, ipv4: old4, ipv6: old6) { _ in "NO_ACTIVE_SPLIT" }
        do {
            try await RoutingRuleUpdate.commit(root: folder, ipv4: rules4(1), ipv6: rules6(1)) { _ in
                do { try await RuleUpdater(folder: folder).commit(old4); XCTFail("Writer bypassed transaction lock") }
                catch RuleCacheFailure.busy {} catch { XCTFail("Unexpected error: \(error)") }
                return "ERROR: fixture rejection"
            }
            XCTFail("Helper failure accepted")
        } catch RuleCacheFailure.helperRejected {}
        let saved = try RuleCacheStore.read(folder)
        XCTAssertEqual(try RuleSet(text: saved.ipv4!).routes, old4.routes)
        XCTAssertEqual(try IPv6RuleSet(text: saved.ipv6!).routes, old6.routes)
        let history = try await RuleUpdater(folder: folder).snapshots()
        XCTAssertTrue(history.isEmpty, "Rejected updates must not accumulate duplicate archives")
    }
    func testPublicationFailureCompensatesLiveHelper() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        let old4 = try rules4(0), old6 = try rules6(0)
        try await RoutingRuleUpdate.commit(root: folder, ipv4: old4, ipv6: old6) { _ in "NO_ACTIVE_SPLIT" }
        var calls = 0
        do {
            try await RoutingRuleUpdate.commit(root: folder, ipv4: rules4(1), ipv6: rules6(1)) { text in
                calls += 1
                if calls == 1 {
                    // Lose the staged rename source after live application.
                    for file in try! FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix(".routing-rules-") { try! FileManager.default.removeItem(at: file) }
                } else {
                    let bundle = try! RoutingRuleBundle.decoded(text)
                    XCTAssertEqual(try! RuleSet(text: bundle.ipv4).routes, old4.routes)
                    XCTAssertEqual(try! IPv6RuleSet(text: bundle.ipv6!).routes, old6.routes)
                }
                return "Rules applied"
            }
            XCTFail("Missing stage published")
        } catch ProfileFileIO.Failure.cannotWrite {}
        XCTAssertEqual(calls, 2)
        let saved = try RuleCacheStore.read(folder)
        XCTAssertEqual(try RuleSet(text: saved.ipv4!).routes, old4.routes)
    }
    func testLegacyMigrationAndBothFamilyPublication() async throws {
        let folder = root(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old4 = try rules4(0), old6 = try rules6(0)
        try old4.routes.map(\.description).joined(separator: "\n").write(to: folder.appendingPathComponent("china-ipv4.txt"), atomically: true, encoding: .utf8)
        try old6.routes.map(\.description).joined(separator: "\n").write(to: folder.appendingPathComponent("china-ipv6-preview.txt"), atomically: true, encoding: .utf8)
        try await RoutingRuleUpdate.commit(root: folder, ipv4: rules4(1), ipv6: rules6(1)) { _ in "NO_ACTIVE_SPLIT" }
        let current4 = try await RuleUpdater(folder: folder).cached(), current6 = try await APNICIPv6PreviewStore(root: folder).cached()
        XCTAssertEqual(current4?.routes, try rules4(1).routes); XCTAssertEqual(current6?.routes, try rules6(1).routes)
    }
}
