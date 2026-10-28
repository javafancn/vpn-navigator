import XCTest
@testable import VPNNavigatorCore

final class SessionRecoveryPolicyTests: XCTestCase {
    func testNormalLifecycleKeepsOwnedJournalsWithoutReportingAbandonedRecovery() {
        let profile = UUID(), attempt = UUID()
        for state in [TunnelState.connecting, .authenticating, .connected, .reconnecting, .stopping] {
            XCTAssertTrue(SessionRecoveryPolicy.hasLiveOwner(state: state, profileID: profile,
                attemptID: attempt, ownedChildRunning: true))
        }
    }
    func testFailedOrStoppedProcessCannotHideRecoveryEvidence() {
        for state in [TunnelState.failed, .disconnected] {
            XCTAssertFalse(SessionRecoveryPolicy.hasLiveOwner(state: state, profileID: UUID(),
                attemptID: UUID(), ownedChildRunning: true))
        }
        for state in [TunnelState.connected, .connecting, .stopping] {
            XCTAssertFalse(SessionRecoveryPolicy.hasLiveOwner(state: state, profileID: UUID(),
                attemptID: UUID(), ownedChildRunning: false))
        }
    }
    func testIncompleteIdentityDoesNotAdoptAnUnverifiedChild() {
        for (profile, attempt) in [(nil, UUID()), (UUID(), nil), (nil, nil)] as [(UUID?, UUID?)] {
            XCTAssertFalse(SessionRecoveryPolicy.hasLiveOwner(state: .connected, profileID: profile,
                attemptID: attempt, ownedChildRunning: true))
        }
    }
}
