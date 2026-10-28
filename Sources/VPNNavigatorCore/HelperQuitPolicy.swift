import Foundation

/// Exiting a process keeps its launchd registration and approval intact.
/// Only an authenticated, idle and completely recovered helper may do so.
public enum HelperQuitPolicy {
    public static func mayStop(_ report: SessionReport, hasRecoveryEvidence: Bool, installationPending: Bool) -> Bool {
        !installationPending && !hasRecoveryEvidence && !report.firewallActive &&
        !report.firewallRecoveryRequired && report.networkRecoveryRequired == false && report.challenge == nil &&
        SessionExitPolicy.mayExit(state: report.state, activeProfileID: report.activeProfileID,
                                 helperVerified: true, recoveryRequired: false)
    }
}

public struct HelperQuitReceipt: Codable, Equatable, Sendable {
    public let schema: Int
    public let operation: String
    public let processID: Int32
    public init(processID: Int32) {
        schema = 1; operation = "idle-helper-exit"; self.processID = processID
    }
    public var json: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
    public static func decode(_ text: String) -> HelperQuitReceipt? {
        guard text.utf8.count < 1024, let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schema == 1, value.operation == "idle-helper-exit", value.processID > 1 else { return nil }
        return value
    }
}
