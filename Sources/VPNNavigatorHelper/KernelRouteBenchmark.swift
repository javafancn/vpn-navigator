#if VPNNAV_LOCAL_TEST
import Foundation
import Darwin
import VPNNavigatorCore

/// Disposable approved CI only: two runs over the same unused benchmarking
/// prefixes. Neither backend touches the default route or sends network data.
enum KernelRouteBenchmark {
    static func run() throws {
        guard getuid() == 0, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              !FileManager.default.fileExists(atPath: "/var/run/vpn-navigator/routes.journal") else { throw RouteExecutionError.ambiguousJournal }
        let path = try RouteExecutor.command("/sbin/route", ["-n", "get", "default"])
        func field(_ name: String) -> String? {
            path.components(separatedBy: .newlines).first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + ":") }?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        }
        guard let gateway = field("gateway"), let interface = field("interface") else { throw RoutePlanningError.invalidGateway }
        _ = try PhysicalIPPath(gateway: gateway, interface: interface)
        let routes = try (0..<512).map { RouteTarget(try IPv4CIDR("198.18.\(248 + $0 / 256).\($0 % 256)/32"), .viaGateway(gateway)) }
        let table = try RouteExecutor.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        guard routes.allSatisfy({ RoutePrefixPresence.ipv4($0.prefix, table: table) == .absent }) else { throw RouteExecutionError.existingRoute("benchmark prefixes") }
        let folder = URL(fileURLWithPath: "/var/run/vpn-navigator").appendingPathComponent("kernel-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var times: [String: Double] = [:]
        for native in [false, true] {
            let journal = folder.appendingPathComponent(native ? "native.journal" : "cli.journal")
            let executor = native ? RouteExecutor(journal: journal) : RouteExecutor(journal: journal, run: RouteExecutor.command)
            defer { executor.rollback() }
            let started = ProcessInfo.processInfo.systemUptime
            try executor.apply(routes)
            times[native ? "native" : "cli"] = ProcessInfo.processInfo.systemUptime - started
            for index in [0, 255, 511] {
                let route = routes[index]
                let observed = try RouteExecutor.command("/sbin/route", ["-n", "get", "-net", route.prefix.description])
                guard ObservedIPv4Route(commandOutput: observed).isExactly(route) else { throw RouteExecutionError.routeOwnershipLost(route.prefix.description) }
            }
            executor.rollback()
            guard executor.installed.isEmpty, !FileManager.default.fileExists(atPath: journal.path) else { throw RouteExecutionError.journalFailure }
            let after = try RouteExecutor.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
            guard routes.allSatisfy({ RoutePrefixPresence.ipv4($0.prefix, table: after) == .absent }) else { throw RouteExecutionError.journalFailure }
        }
        try FileManager.default.removeItem(at: folder)
        print("METRIC: 512 real IPv4 routes with identical per-mutation fsync: " + String(decoding: try JSONEncoder().encode(times), as: UTF8.self))
        print("PASS: native routing socket and CLI install identical real routes, verify ownership and roll back completely.")
    }
}
#endif
