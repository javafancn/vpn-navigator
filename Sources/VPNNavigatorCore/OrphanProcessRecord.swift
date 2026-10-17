import Foundation

/// Root-private record written immediately after a managed OpenVPN child
/// launches. This is evidence for an *absence-only* cleanup decision,
/// never authorization to send a signal to an arbitrary PID.
public struct OrphanProcessRecord: Codable, Equatable, Sendable {
    public let pid: Int32
    public let sessionID: UUID

    public init(pid: Int32, sessionID: UUID = UUID()) throws {
        guard pid > 1 else { throw OrphanProcessError.invalidPID }
        self.pid = pid
        self.sessionID = sessionID
    }
}

/// A non-reused PID cannot exist simultaneously in two processes. Seeing
/// ESRCH means the original pid is gone. An alive/reused PID is **ambiguous**
/// and must never be killed or implicitly trusted after a helper restart.
public enum OrphanProcessRecovery {
    public static func canClearStaleMarker(pidRecordPresent: Bool,
                                          pidConfirmedAbsent: Bool) -> Bool {
        pidRecordPresent && pidConfirmedAbsent
    }
}
public enum OrphanProcessError: Error { case invalidPID }
