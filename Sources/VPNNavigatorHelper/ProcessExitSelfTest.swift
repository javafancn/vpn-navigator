#if DEBUG
import Foundation

enum ProcessExitSelfTest {
    static func run() throws {
        let queue = DispatchQueue(label: "VPNNavigator.ProcessExitFixture")
        let child = Process(), output = Pipe(), input = Pipe(), finished = DispatchSemaphore(value: 0)
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "trap '' TERM; echo READY; read token; exit 0"]
        child.standardOutput = output; child.standardInput = input
        let waiter = ProcessExitWaiter(queue: queue)
        var sawTimeout = false, queueProgressed = false, prematureCleanup = false, retainedAfterTimeout = false
        child.terminationHandler = { process in queue.async { waiter.didExit(process) } }
        try child.run()
        defer { try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        let ready = output.fileHandleForReading.availableData
        guard String(decoding: ready, as: UTF8.self).contains("READY") else { throw Failure.check }
        queue.async {
            waiter.wait(for: child, timeout: 0.02, onExit: {
                prematureCleanup = child.isRunning
                finished.signal()
            }, onTimeout: {
                sawTimeout = true
                retainedAfterTimeout = waiter.isWaiting(for: child) && waiter.hasTimedOut(for: child) && !waiter.didExit(child)
                try? input.fileHandleForWriting.write(contentsOf: Data("EXIT\n".utf8))
            })
            child.terminate()
            queue.async { queueProgressed = true }
        }
        guard finished.wait(timeout: .now() + 3) == .success else { throw Failure.check }
        let passed = queue.sync {
            sawTimeout && retainedAfterTimeout && queueProgressed && !prematureCleanup &&
                !waiter.isWaiting(for: child) && !waiter.hasTimedOut(for: child)
        }
        guard passed else { throw Failure.check }
        print("PASS: asynchronous stop leaves the session queue responsive, times out conservatively, and finalizes only after the owned child actually exits.")
    }
    enum Failure: Error { case check }
}
#endif
