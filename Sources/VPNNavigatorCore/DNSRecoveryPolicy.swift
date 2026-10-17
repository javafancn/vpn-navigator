import Foundation

public enum DNSRestoreDecision: Equatable { case unchanged, restoreOwnedValue, conflict }
public enum DNSRecoveryPolicy {
    public static func decide(currentMatchesOriginal: Bool, currentMatchesApplied: Bool, committed: Bool) -> DNSRestoreDecision {
        if currentMatchesOriginal { return .unchanged }
        if committed && currentMatchesApplied { return .restoreOwnedValue }
        return .conflict
    }
    public static func validServiceID(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    public static func validTunnel(_ value: String) -> Bool {
        value.hasPrefix("utun") && (1...4).contains(value.dropFirst(4).count) &&
            value.dropFirst(4).allSatisfy { $0.isASCII && $0.isNumber }
    }
}
