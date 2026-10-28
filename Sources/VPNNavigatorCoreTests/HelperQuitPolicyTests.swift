import XCTest
@testable import VPNNavigatorCore

final class HelperQuitPolicyTests: XCTestCase {
    private func report(_ state: TunnelState = .disconnected, active: UUID? = nil,
                        firewall: Bool = false, firewallRecovery: Bool = false, recovery: Bool? = false) -> SessionReport {
        .init(state: state, message: "fixture", activeProfileID: active, receivedBytes: nil, sentBytes: nil,
              firewallActive: firewall, firewallRecoveryRequired: firewallRecovery, networkRecoveryRequired: recovery)
    }
    private func canStop(_ value: SessionReport) -> Bool {
        HelperQuitPolicy.mayStop(value, hasRecoveryEvidence: false, installationPending: false)
    }
    func testRecoveredIdleAndFailedSessionsCanExit() {
        XCTAssertTrue(canStop(report()))
        XCTAssertTrue(canStop(report(.failed)))
    }
    func testActiveAndTransitionalSessionsCannotExit() {
        for state in [TunnelState.connected, .connecting, .authenticating, .reconnecting, .stopping] {
            XCTAssertFalse(canStop(report(state)))
        }
        XCTAssertFalse(canStop(report(active: UUID())))
    }
    func testProtectionAndNetworkRecoveryCannotExit() {
        XCTAssertFalse(canStop(report(firewall: true)))
        XCTAssertFalse(canStop(report(firewallRecovery: true)))
        XCTAssertFalse(canStop(report(recovery: true)))
    }
    func testMissingRecoveryVerificationCannotExit() {
        XCTAssertFalse(canStop(report(recovery: nil)))
    }
    func testPersistentEvidenceAndPendingInstallationCannotExit() {
        XCTAssertFalse(HelperQuitPolicy.mayStop(report(), hasRecoveryEvidence: true, installationPending: false))
        XCTAssertFalse(HelperQuitPolicy.mayStop(report(), hasRecoveryEvidence: false, installationPending: true))
    }
    func testReceiptRoundTrip() {
        let receipt = HelperQuitReceipt(processID: 42)
        XCTAssertEqual(HelperQuitReceipt.decode(receipt.json), receipt)
    }
    func testReceiptRejectsUnsafeProcessIDsAndOtherOperations() {
        for pid in [Int32(-1), 0, 1] { XCTAssertNil(HelperQuitReceipt.decode(HelperQuitReceipt(processID: pid).json)) }
        XCTAssertNil(HelperQuitReceipt.decode("{\"schema\":1,\"operation\":\"uninstall\",\"processID\":42}"))
        XCTAssertNil(HelperQuitReceipt.decode("{\"schema\":2,\"operation\":\"idle-helper-exit\",\"processID\":42}"))
    }
    func testReceiptRejectsErrorsMalformedAndOversizedInput() {
        for text in ["ERROR: recovery required", "{}", "42", String(repeating: " ", count: 1024)] {
            XCTAssertNil(HelperQuitReceipt.decode(text))
        }
    }
}
