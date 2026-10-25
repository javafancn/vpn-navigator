#if DEBUG
import Foundation
import VPNNavigatorCore

enum RouteExecutionSelfTest {
    static func run() throws {
        try DualStackRouteSelfTest.run()
        try RouteSwitchSelfTest.run()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var calls: [[String]] = []
        let first = RouteTarget(try IPv4CIDR("223.5.5.0/24"), .viaGateway("192.168.1.1"))
        let occupied = RouteTarget(try IPv4CIDR("223.5.6.0/24"), .viaGateway("192.168.1.1"))
        let executor = RouteExecutor(journal: folder.appendingPathComponent("routes"), run: { executable, args in
            calls.append(args)
            if executable == "/usr/sbin/netstat" { return "223.5.6.0/24 192.168.1.1 en0\n" }
            if args.contains("get") { return "destination: 223.5.5.0\nmask: 255.255.255.0\ngateway: 192.168.1.1\ninterface: en0" }
            return ""
        })
        do { try executor.apply([first, occupied]); throw RouteExecutionError.journalFailure }
        catch RouteExecutionError.existingRoute { }
        guard executor.installed == [first], !calls.contains(where: { $0.contains("delete") || $0.contains("get") }) else {
            throw RouteExecutionError.journalFailure
        }
        // The caller now confirms the child has exited, then explicitly rolls back.
        executor.rollback()
        guard executor.installed.isEmpty, calls.contains(where: { $0.contains("delete") }) else { throw RouteExecutionError.journalFailure }
        let cancelled = RouteExecutor(journal: folder.appendingPathComponent("cancelled"), shouldCancel: { true }, run: { _, _ in
            throw RouteExecutionError.disallowedExecutable
        })
        do { try cancelled.apply(first); throw RouteExecutionError.journalFailure }
        catch is CancellationError { }
    }
}
#endif
