import XCTest
@testable import VPNNavigatorCore

final class SessionCancellationTests: XCTestCase {
    func testCancelArrivingBeforeConnectStillCancelsThatAttempt() {
        let registry = SessionCancellation(), attempt = UUID()
        registry.cancel(attempt)
        let connectArrivesLater = registry.snapshot()
        XCTAssertTrue(registry.isCancelled(attempt, generation: connectArrivesLater))
        XCTAssertFalse(registry.isCancelled(UUID(), generation: connectArrivesLater))
    }
    func testQueuedConnectAndRouteBatchObserveGlobalStop() {
        let registry = SessionCancellation(), attempt = UUID()
        let captured = registry.snapshot()
        XCTAssertFalse(registry.isCancelled(attempt, generation: captured))
        registry.cancel(nil)
        XCTAssertTrue(registry.isCancelled(attempt, generation: captured))
    }
}
