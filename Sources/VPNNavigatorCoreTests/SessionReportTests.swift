import XCTest
@testable import VPNNavigatorCore

final class SessionReportTests: XCTestCase {
    func testNativeStatusAndByteCountsRoundTrip() throws {
        let id = UUID()
        let report = SessionReport(state: .connected, message: "Ready",
            activeProfileID: id, receivedBytes: 4096, sentBytes: 1200)
        let restored = try JSONDecoder().decode(
            SessionReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(restored, report)
        XCTAssertEqual(restored.statusText, "connected: Ready")
        XCTAssertEqual(restored.activeProfileID, id)
        XCTAssertEqual(restored.traffic?.receivedBytes, 4096)
    }
    func testDisconnectedStatusDoesNotInventTraffic() throws {
        let report = SessionReport(state: .disconnected, message: "Disconnected",
            activeProfileID: nil, receivedBytes: nil, sentBytes: nil)
        XCTAssertNil(report.traffic)
        XCTAssertNil(report.activeProfileID)
    }
    func testDNSOrRouteEvidencePreventsQuitAfterProcessHasExited() throws {
        let report = SessionReport(state: .failed, message: "Recovery required", activeProfileID: nil,
                                   receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: true)
        let restored = try JSONDecoder().decode(SessionReport.self, from: JSONEncoder().encode(report))
        XCTAssertTrue(restored.requiresNetworkRecovery)
        XCTAssertFalse(SessionExitPolicy.mayExit(state: restored.state, activeProfileID: nil, helperVerified: true,
                                                recoveryRequired: restored.requiresNetworkRecovery))
    }
    func testLegacyFailedSnapshotRequiresExplicitRecovery() throws {
        let report = SessionReport(state: .failed, message: "", activeProfileID: nil, receivedBytes: nil, sentBytes: nil)
        let restored = try JSONDecoder().decode(SessionReport.self, from: JSONEncoder().encode(report))
        XCTAssertNil(restored.networkRecoveryRequired)
        XCTAssertTrue(restored.requiresNetworkRecovery)
        let recovered = SessionReport(state: .failed, message: "Authentication failed", activeProfileID: nil,
                                      receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: false)
        XCTAssertFalse(recovered.requiresNetworkRecovery)
        XCTAssertTrue(SessionExitPolicy.mayExit(state: recovered.state, activeProfileID: nil, helperVerified: true, recoveryRequired: false))
    }
    func testActiveUnverifiedAndUnresolvedSessionsCannotExit() {
        for state: TunnelState in [.connecting, .authenticating, .connected, .reconnecting, .stopping] {
            XCTAssertFalse(SessionExitPolicy.mayExit(state: state, activeProfileID: nil, helperVerified: true, recoveryRequired: false))
        }
        XCTAssertFalse(SessionExitPolicy.mayExit(state: .disconnected, activeProfileID: nil, helperVerified: false, recoveryRequired: false))
        XCTAssertFalse(SessionExitPolicy.mayExit(state: .failed, activeProfileID: UUID(), helperVerified: true, recoveryRequired: false))
        XCTAssertFalse(SessionExitPolicy.mayExit(state: .disconnected, activeProfileID: nil, helperVerified: true, recoveryRequired: true))
    }
}

