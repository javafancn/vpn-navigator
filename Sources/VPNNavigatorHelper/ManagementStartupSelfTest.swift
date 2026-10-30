#if DEBUG
import Foundation
import Darwin
import VPNNavigatorCore

/// Disposable CI only. Exercises the production waiter with real child
/// processes, root-authenticated Unix sockets and asynchronous output pipes.
enum ManagementStartupSelfTest {
    static func run() throws {
        guard getuid() == 0, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        for scenario in ["delayed", "cancel", "deadline", "config-exit", "certificate-exit", "silent-exit", "listener-error"] {
            try exercise(scenario)
            print("PASS: management startup " + scenario)
        }
    }
    private static func exercise(_ scenario: String) throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("vpnnav-start-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("m.sock").path
        let listener = try ManagementListener(path: path)
        defer { listener.close() }
        let socket = ManagementSocket(), output = OpenVPNStartupOutput(), pipe = Pipe()
        let exited = DispatchSemaphore(value: 0)
        socket.onExit = { exited.signal() }
        defer { socket.close() }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { output.finish(); handle.readabilityHandler = nil }
            else { output.receive(bytes) }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil; try? pipe.fileHandleForReading.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Fixed synthetic code, compiled out of release builds. No user input
        // is evaluated, no real configuration/credentials or network mutations.
        child.arguments = ["-c", """
        import socket, sys, time
        name, path = sys.argv[1:]
        if name == 'config-exit':
            sys.stderr.write('Options Error: unsupported synthetic option secret=not-for-reports'); sys.exit(2)
        if name == 'certificate-exit':
            sys.stderr.write('Cannot load certificate file: synthetic-private-name'); sys.exit(3)
        if name == 'silent-exit': sys.exit(4)
        time.sleep(6.2)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.connect(path)
            with peer.makefile('rb') as stream:
                actual = [stream.readline().decode().strip() for _ in range(3)]
                assert actual == ['state on', 'bytecount 1', 'hold release']
        """, scenario, path]
        child.standardOutput = pipe; child.standardError = pipe
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        if scenario == "listener-error" { listener.close() }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try ManagementStartup.wait(socket: socket, listener: listener, process: child, output: output) {
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                if scenario == "cancel", elapsed > 0.2 { throw CancellationError() }
                if elapsed > (scenario == "deadline" ? 0.2 : 10) { throw TunnelError.connectionTimedOut }
            }
            guard scenario == "delayed", ProcessInfo.processInfo.systemUptime - started > 5,
                  exited.wait(timeout: .now() + 2) == .success else { throw Failure.check }
        } catch is CancellationError {
            guard scenario == "cancel", child.isRunning, ProcessInfo.processInfo.systemUptime - started < 2 else { throw Failure.check }
        } catch TunnelError.connectionTimedOut {
            guard scenario == "deadline", child.isRunning, ProcessInfo.processInfo.systemUptime - started < 2 else { throw Failure.check }
        } catch let failure as OpenVPNStartupError {
            let expected: DiagnosticCode = scenario == "config-exit" ? .configuration : scenario == "certificate-exit" ? .certificate : .unexpectedExit
            let status: Int32 = scenario == "config-exit" ? 2 : scenario == "certificate-exit" ? 3 : 4
            guard ["config-exit", "certificate-exit", "silent-exit"].contains(scenario), failure.code == expected,
                  failure.exitStatus == status, !child.isRunning, ProcessInfo.processInfo.systemUptime - started < 3,
                  !failure.localizedDescription.contains("not-for-reports"),
                  !failure.localizedDescription.contains("synthetic-private-name") else { throw Failure.check }
        } catch ManagementError.socket {
            guard scenario == "listener-error", ProcessInfo.processInfo.systemUptime - started < 2 else { throw Failure.check }
        }
    }
    private enum Failure: Error { case check }
}
#endif
