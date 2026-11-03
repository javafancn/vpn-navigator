import Foundation

/// Confined to the session queue. A timeout reports failure but keeps ownership
/// of the child; a later termination notification can still finish cleanup.
final class ProcessExitWaiter {
    private let queue: DispatchQueue
    private var process: Process?
    private var deadline: DispatchWorkItem?
    private var exited: (() -> Void)?
    private var timedOut = false
    init(queue: DispatchQueue) { self.queue = queue }
    func isWaiting(for value: Process) -> Bool { process === value }
    func hasTimedOut(for value: Process) -> Bool { process === value && timedOut }
    func wait(for value: Process, timeout: TimeInterval = 2, onExit: @escaping () -> Void, onTimeout: @escaping () -> Void) {
        precondition(process == nil)
        process = value; exited = onExit; timedOut = false
        guard value.isRunning else { didExit(value); return }
        let work = DispatchWorkItem { [weak self, weak value] in
            guard let self, let value, self.process === value else { return }
            if !value.isRunning { self.didExit(value) }
            else { self.deadline = nil; self.timedOut = true; onTimeout() }
        }
        deadline = work; queue.asyncAfter(deadline: .now() + timeout, execute: work)
    }
    @discardableResult func didExit(_ value: Process) -> Bool {
        guard process === value, !value.isRunning else { return false }
        deadline?.cancel(); deadline = nil; process = nil; timedOut = false
        let completion = exited; exited = nil; completion?()
        return true
    }
}
