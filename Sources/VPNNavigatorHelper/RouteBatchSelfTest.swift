#if DEBUG
import Foundation
import VPNNavigatorCore

enum RouteBatchSelfTest {
    final class Fixture {
        var live: [String: RouteTarget] = [:]
        var mutations = 0
        var failAt: Int?
        var cancelAt: Int?
        var cancelled = false
        var syncs = 0
        var failSync: Int?
        let journal: URL
        init(_ journal: URL) { self.journal = journal }
        func run(_ command: String, _ args: [String]) throws -> String {
            if command == "/usr/sbin/netstat" {
                return "Internet:\nDestination Gateway Flags Netif\n" + live.keys.map { "\($0) 192.0.2.1 UGSc en0" }.joined(separator: "\n")
            }
            guard let prefix = args.first(where: { $0.contains("/") }) else { throw Failure.check }
            if args.contains("get") {
                guard let route = live[prefix] else { return "destination: default\ninterface: en0\ngateway: 192.0.2.1" }
                return "destination: \(IPv4CIDR.parseAddressString(route.prefix.network))\nmask: \(route.prefix.netmask)\ngateway: 192.0.2.1\ninterface: en0"
            }
            // Every kernel write must have a previously synchronized intent.
            let replay = RouteLedgerReplay(data: try Data(contentsOf: journal))
            guard replay.uncertain.contains(where: { $0.route.prefix.description == prefix }), syncs > 0 else { throw Failure.check }
            mutations += 1
            if mutations == failAt { throw Failure.kernel }
            if args.contains("add") { live[prefix] = .init(try IPv4CIDR(prefix), .viaGateway("192.0.2.1")) }
            else { live.removeValue(forKey: prefix) }
            if mutations == cancelAt { cancelled = true }
            return ""
        }
        func sync(_ handle: FileHandle) throws {
            syncs += 1
            if syncs == failSync { throw Failure.durability }
            try handle.synchronize()
        }
        func executor() -> RouteExecutor {
            RouteExecutor(journal: journal, shouldCancel: { self.cancelled }, run: run, synchronize: sync)
        }
    }
    static func run() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("route-batch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let routes = try (0..<256).map { RouteTarget(try IPv4CIDR("11.0.\($0).0/24"), .viaGateway("192.0.2.1")) }
        let success = Fixture(folder.appendingPathComponent("success")), executor = success.executor()
        try executor.apply(routes)
        guard success.syncs == 8, executor.installed == routes else { throw Failure.check }
        executor.rollback()
        guard success.syncs == 16, success.live.isEmpty, executor.installed.isEmpty,
              !FileManager.default.fileExists(atPath: success.journal.path) else { throw Failure.check }

        let failed = Fixture(folder.appendingPathComponent("kernel-failure")); failed.failAt = 3
        let blocked = failed.executor()
        do { try blocked.apply(routes); throw Failure.check } catch Failure.kernel { }
        let pending = RouteLedgerReplay(data: try Data(contentsOf: failed.journal))
        guard !pending.malformed, pending.uncertain.count == 1, pending.uncertain[0].route == routes[2],
              pending.installed == Array(routes.prefix(2)) else { throw Failure.check }
        blocked.rollback()
        guard failed.live.count == 2 else { throw Failure.check }
        try RouteJournalRecovery.reconcileAbsentAdds(failed.journal, run: failed.run)
        _ = RouteExecutor(journal: failed.journal, run: failed.run)
        guard failed.live.isEmpty, !FileManager.default.fileExists(atPath: failed.journal.path) else { throw Failure.check }

        let cancelled = Fixture(folder.appendingPathComponent("cancelled")); cancelled.cancelAt = 3
        let stopping = cancelled.executor()
        do { try stopping.apply(routes); throw Failure.check } catch is CancellationError { }
        let cancelledReplay = RouteLedgerReplay(data: try Data(contentsOf: cancelled.journal))
        guard cancelledReplay.permitsAutomaticRecovery, cancelledReplay.installed == Array(routes.prefix(3)) else { throw Failure.check }
        stopping.rollback()
        guard cancelled.live.isEmpty, stopping.installed.isEmpty else { throw Failure.check }

        for failSync in [1, 2] {
            let failed = Fixture(folder.appendingPathComponent("sync-\(failSync)")); failed.failSync = failSync
            let stopped = failed.executor()
            do { try stopped.apply(Array(routes.prefix(64))); throw Failure.check } catch Failure.durability { }
            let writes = failed.mutations
            stopped.rollback()
            guard failed.mutations == writes, writes == (failSync == 1 ? 0 : 64),
                  FileManager.default.fileExists(atPath: failed.journal.path) else { throw Failure.check }
        }
        print("PASS: 256 route adds/removes use 16 journal syncs instead of 1024; durable intents precede every write; failed writes, cancellation and intent/receipt sync failures remain conservative.")
    }
    enum Failure: Error { case check, kernel, durability }
}
#endif
