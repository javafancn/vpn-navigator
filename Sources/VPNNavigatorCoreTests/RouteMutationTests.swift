import XCTest
@testable import VPNNavigatorCore

final class RouteMutationTests: XCTestCase {
    func testDurablePendingMutationRoundTrips() throws {
        let route = RouteTarget(try IPv4CIDR("223.5.5.0/24"), .viaGateway("192.168.1.1"))
        for action in [RouteMutation.Action.add, .remove] {
            let original = RouteMutation(action: action, route: route)
            let restored = try JSONDecoder().decode(RouteMutation.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(restored, original)
        }
    }

    func testRecoveryRequiresNoUncertainInFlightChange() {
        XCTAssertTrue(RouteRecoveryGate.canAutomaticallyRecover(
            hasPendingMutation: false, hasOrphanedOpenVPN: false))
        XCTAssertFalse(RouteRecoveryGate.canAutomaticallyRecover(
            hasPendingMutation: true, hasOrphanedOpenVPN: false))
        XCTAssertFalse(RouteRecoveryGate.canAutomaticallyRecover(
            hasPendingMutation: false, hasOrphanedOpenVPN: true))
        XCTAssertFalse(RouteRecoveryGate.canAutomaticallyRecover(
            hasPendingMutation: true, hasOrphanedOpenVPN: true))
    }
}
