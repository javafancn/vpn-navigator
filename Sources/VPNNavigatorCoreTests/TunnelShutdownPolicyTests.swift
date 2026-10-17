import XCTest
@testable import VPNNavigatorCore

final class TunnelShutdownPolicyTests: XCTestCase {
    func testOrphanMarkersCannotBeRemovedByOrdinaryDisconnect() {
        XCTAssertFalse(TunnelShutdownPolicy.mayFinalizeSessionCleanup(
            ownedChildProcess: false, childExited: false, hasPersistentSessionEvidence: true))
        XCTAssertFalse(TunnelShutdownPolicy.mayFinalizeSessionCleanup(
            ownedChildProcess: false, childExited: true, hasPersistentSessionEvidence: true))
        XCTAssertTrue(TunnelShutdownPolicy.mayFinalizeSessionCleanup(
            ownedChildProcess: false, childExited: false, hasPersistentSessionEvidence: false))
    }

    func testOwnedProcessCanOnlyBeCleanedAfterExit() {
        XCTAssertFalse(TunnelShutdownPolicy.mayFinalizeSessionCleanup(
            ownedChildProcess: true, childExited: false, hasPersistentSessionEvidence: true))
        XCTAssertTrue(TunnelShutdownPolicy.mayFinalizeSessionCleanup(
            ownedChildProcess: true, childExited: true, hasPersistentSessionEvidence: true))
    }

    func testNeverRestoreRoutesBeforeOpenVPNProcessExit() {
        XCTAssertFalse(TunnelShutdownPolicy.mayRestoreRoutes(openVPNExited: false))
        XCTAssertTrue(TunnelShutdownPolicy.mayRestoreRoutes(openVPNExited: true))
    }
}
