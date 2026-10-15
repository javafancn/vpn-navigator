import XCTest
@testable import VPNNavigatorCore

final class TunnelShutdownPolicyTests: XCTestCase {
    func testNeverRestoreRoutesBeforeOpenVPNProcessExit() {
        XCTAssertFalse(TunnelShutdownPolicy.mayRestoreRoutes(openVPNExited: false))
        XCTAssertTrue(TunnelShutdownPolicy.mayRestoreRoutes(openVPNExited: true))
    }
}
