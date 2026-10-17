import Foundation

/// XPC requests can arrive on different connections. Remember an explicitly
/// cancelled attempt even when Cancel reaches the helper before Connect.
public final class SessionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var cancelled: [UUID] = []
    public init() { }
    public func snapshot() -> UInt64 {
        lock.lock(); defer { lock.unlock() }; return generation
    }
    public func cancel(_ id: UUID?) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        if let id, !cancelled.contains(id) {
            cancelled.append(id)
            if cancelled.count > 128 { cancelled.removeFirst(cancelled.count - 128) }
        }
    }
    public func isCancelled(_ id: UUID, generation captured: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation != captured || cancelled.contains(id)
    }
}
