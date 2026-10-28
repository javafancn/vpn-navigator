#if DEBUG || VPNNAV_LOCAL_TEST
import Foundation
import Darwin
import VPNNavigatorCore

/// Only loopback route GETs reach the real kernel; add/delete calls are simulated.
enum RouteCommandPressureSelfTest {
    static func run(legacy: Bool = false) throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw RouteExecutionError.disallowedExecutable }
        var previous = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &previous) == 0 else { throw RouteExecutionError.journalFailure }
        var limited = previous
        limited.rlim_cur = min(previous.rlim_cur, 128)
        guard setrlimit(RLIMIT_NOFILE, &limited) == 0 else { throw RouteExecutionError.journalFailure }
        defer { _ = setrlimit(RLIMIT_NOFILE, &previous) }
        let started = ProcessInfo.processInfo.systemUptime
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var commands = 0
        func probe() throws {
            do {
                #if DEBUG
                if legacy { _ = try legacyCommand() }
                else { _ = try RouteExecutor.command("/sbin/route", ["-n", "get", "127.0.0.1"]) }
                #else
                _ = try RouteExecutor.command("/sbin/route", ["-n", "get", "127.0.0.1"])
                #endif
                commands += 1
            } catch {
                print("Route pressure stopped after \(commands) commands: \(error.localizedDescription)")
                throw error
            }
        }
        func descriptors() -> Int { (0..<Int(limited.rlim_cur)).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
        try probe()
        let baseline = descriptors()
        if legacy {
            for _ in 0..<128 { try probe() }
            print("Legacy observation completed 128 commands; descriptors \(baseline) -> \(descriptors()); elapsed \(Int(ProcessInfo.processInfo.systemUptime - started))s.")
            return
        }
        let routes = try (0..<512).map {
            RouteTarget(try IPv4CIDR("198.18.\($0 / 256).\($0 % 256)/32"), .viaGateway("192.0.2.1"))
        }
        var system: [String: RouteTarget] = [:]
        let journal = folder.appendingPathComponent("routes.journal")
        let executor = RouteExecutor(journal: journal, run: { executable, args in
            if executable == "/usr/sbin/netstat" { return "Internet:\nDestination Gateway Flags Netif\n" }
            guard executable == "/sbin/route", let index = args.firstIndex(of: "-net"), args.count > index + 1 else {
                throw RouteExecutionError.disallowedExecutable
            }
            let prefix = args[index + 1]
            if args.contains("get") {
                if let route = system[prefix] {
                    return "destination: \(route.prefix.description.split(separator: "/")[0])\nmask: 255.255.255.255\ngateway: 192.0.2.1\ninterface: en0"
                }
                return "destination: default\ngateway: 192.0.2.1\ninterface: en0"
            }
            try probe()
            if args.contains("add"), let route = routes.first(where: { $0.prefix.description == prefix }) { system[prefix] = route }
            else if args.contains("delete") { system.removeValue(forKey: prefix) }
            else { throw RouteExecutionError.disallowedExecutable }
            return ""
        })
        try executor.apply(routes)
        for _ in 0..<2048 { try probe() }
        executor.rollback()
        guard executor.installed.isEmpty, system.isEmpty, !FileManager.default.fileExists(atPath: journal.path),
              descriptors() <= baseline + 8, commands == 3073 else { throw RouteExecutionError.journalFailure }
        let seconds = Int(ProcessInfo.processInfo.systemUptime - started)
        print("PASS: 3,072 real read-only route subprocesses and 512 journaled synthetic routes under a 128-FD limit; descriptors remain bounded; elapsed \(seconds)s.")
    }

    #if DEBUG
    static func observeLegacyBehavior() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { return }
        try autoreleasepool {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            task.arguments = ["--self-test-route-pressure-legacy"]
            let pipe = Pipe()
            defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = pipe
            task.standardError = pipe
            try task.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            print("Legacy command resource observation (isolated child, exit \(task.terminationStatus)): " +
                  String(decoding: bytes.suffix(1000), as: UTF8.self))
        }
    }
    private static func legacyCommand() throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/route")
        task.arguments = ["-n", "get", "127.0.0.1"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw RouteExecutionError.commandFailed("/sbin/route") }
        return String(decoding: bytes, as: UTF8.self)
    }
    #endif
}
#endif
