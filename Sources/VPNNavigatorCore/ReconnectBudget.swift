import Foundation

/// A guarded retry is a new owned session, never a release of the firewall.
/// Keep a bounded budget so bad credentials/network flaps cannot loop forever.
public struct ReconnectBudget: Sendable {
    private var began: Date
    public private(set) var attempts = 0
    public init(now: Date = Date()) { began = now }
    public mutating func nextDelay(guardVerified: Bool, optedIn: Bool, now: Date = Date()) -> Int? {
        guard guardVerified, optedIn else { return nil }
        if now.timeIntervalSince(began) > 600 { began = now; attempts = 0 }
        guard attempts < 3 else { return nil }
        attempts += 1
        return 1 << (attempts - 1)
    }
}
