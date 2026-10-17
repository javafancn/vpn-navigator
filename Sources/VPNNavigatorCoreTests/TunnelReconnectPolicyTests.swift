import XCTest
@testable import VPNNavigatorCore

final class TunnelReconnectPolicyTests: XCTestCase {
    func testManagedReconnectCannotOutliveOwnedRoutePolicy() {
        XCTAssertEqual(TunnelReconnectPolicy.action(for: .original), .permitOpenVPNReconnect)
        XCTAssertEqual(TunnelReconnectPolicy.action(for: .fullVPN), .stopAndRestoreOnlyAfterExit)
        XCTAssertEqual(TunnelReconnectPolicy.action(for: .chinaDirect), .stopAndRestoreOnlyAfterExit)
    }
}
