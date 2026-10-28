import Foundation

/// Journals are deliberately retained while their own child is running. They
/// describe pending recovery only after ownership or normal session state is
/// lost. A recovered numeric PID is never an owned child for this decision.
public enum SessionRecoveryPolicy {
    public static func hasLiveOwner(state: TunnelState, profileID: UUID?, attemptID: UUID?, ownedChildRunning: Bool) -> Bool {
        guard ownedChildRunning, profileID != nil, attemptID != nil else { return false }
        switch state {
        case .connecting, .authenticating, .connected, .reconnecting, .stopping: return true
        case .failed, .disconnected: return false
        }
    }
}
