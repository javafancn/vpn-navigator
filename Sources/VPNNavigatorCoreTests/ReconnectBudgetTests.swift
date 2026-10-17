import XCTest
@testable import VPNNavigatorCore

final class ReconnectBudgetTests: XCTestCase {
    func testRetryRequiresBothOptInAndVerifiedFirewall() {
        var budget = ReconnectBudget()
        XCTAssertNil(budget.nextDelay(guardVerified: false, optedIn: true))
        XCTAssertNil(budget.nextDelay(guardVerified: true, optedIn: false))
        XCTAssertEqual(budget.attempts, 0)
    }
    func testRetryBackoffAndWindowAreBounded() {
        let now = Date()
        var budget = ReconnectBudget(now: now)
        XCTAssertEqual(budget.nextDelay(guardVerified: true, optedIn: true, now: now), 1)
        XCTAssertEqual(budget.nextDelay(guardVerified: true, optedIn: true, now: now), 2)
        XCTAssertEqual(budget.nextDelay(guardVerified: true, optedIn: true, now: now), 4)
        XCTAssertNil(budget.nextDelay(guardVerified: true, optedIn: true, now: now.addingTimeInterval(599)))
        XCTAssertEqual(budget.nextDelay(guardVerified: true, optedIn: true, now: now.addingTimeInterval(601)), 1)
    }
}
