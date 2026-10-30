import Foundation
import VPNNavigatorCore

/// The pipe is drained independently of the session queue during startup.
/// Keep only a bounded partial line and a safe error category, never raw logs.
final class OpenVPNStartupOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let ended = DispatchSemaphore(value: 0)
    private var log = OpenVPNStartupLog()
    private var finished = false
    func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        log.receive(data)
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true; log.finish(); ended.signal()
    }
    func failureAfterExit() -> DiagnosticCode {
        // EOF and Process exit notifications can arrive in either order.
        // Bounded wait lets the pipe deliver the final (possibly unterminated)
        // diagnostic without waiting on the blocked session queue.
        _ = ended.wait(timeout: .now() + .milliseconds(500))
        lock.lock(); defer { lock.unlock() }
        if !finished { log.finish() }
        return log.failure ?? .unexpectedExit
    }
}

struct OpenVPNStartupError: Error, LocalizedError {
    let code: DiagnosticCode
    let exitStatus: Int32
    var errorDescription: String? {
        L10n.format("OpenVPN exited before its control channel was ready (status {0}). {1}",
            [String(exitStatus), code.summary])
    }
}

enum ManagementStartup {
    /// A cold launch gets the same monotonic, cancellable connection deadline
    /// as TLS/authentication. There is no separate five-second startup cutoff.
    static func wait(socket: ManagementSocket, listener: ManagementListener,
                     process: Process, output: OpenVPNStartupOutput,
                     check: () throws -> Void) throws {
        while true {
            try check()
            if !process.isRunning {
                throw OpenVPNStartupError(code: output.failureAfterExit(), exitStatus: process.terminationStatus)
            }
            // Do not swallow descriptor, peer-identity or initialization errors
            // and then misreport them as a startup timeout.
            do { if try socket.accept(from: listener) { return } }
            catch {
                if !process.isRunning {
                    throw OpenVPNStartupError(code: output.failureAfterExit(), exitStatus: process.terminationStatus)
                }
                throw error
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
