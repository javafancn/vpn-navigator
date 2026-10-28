#if DEBUG
import Foundation
import VPNNavigatorCore

enum RouteJournalRecoverySelfTest {
    static func run() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = folder.appendingPathComponent("routes.journal")
        let owned = RouteTarget(try IPv4CIDR("198.51.100.0/24"), .viaGateway("192.0.2.1"))
        let missing = RouteTarget(try IPv4CIDR("203.0.113.0/24"), .viaGateway("192.0.2.1"))
        func data(pending: RouteMutation) throws -> Data {
            let committed = RouteMutation(action: .add, route: owned)
            let events = [RouteLedgerEvent(phase: .begun, mutation: committed),
                          RouteLedgerEvent(phase: .committed, mutation: committed),
                          RouteLedgerEvent(phase: .begun, mutation: pending)]
            var result = Data()
            for event in events { result.append(try JSONEncoder().encode(event)); result.append(10) }
            return result
        }
        let original = try data(pending: RouteMutation(action: .add, route: missing))
        let table = "Internet:\nDestination Gateway Flags Netif\ndefault 192.0.2.1 UGScg en0\n198.51.100/24 192.0.2.1 UGSc en0\n"
        func reject(_ bytes: Data, table: String) throws {
            try ProfileFileIO.write(bytes, to: journal)
            var refused = false
            do { try RouteJournalRecovery.reconcileAbsentAdds(journal, run: { _, _ in table }) }
            catch { refused = true }
            guard refused, try ProfileFileIO.read(journal) == bytes else { throw RouteExecutionError.journalFailure }
        }
        try reject(original, table: table + "203.0.113/24 192.0.2.99 UGScI utun9\n")
        try reject(original, table: "unreadable table")
        try reject(try data(pending: RouteMutation(action: .remove, route: owned)), table: table)
        try reject(Data("{ truncated".utf8), table: table)
        try ProfileFileIO.write(original, to: journal)
        try RouteJournalRecovery.reconcileAbsentAdds(journal, run: { _, _ in table })
        let replay = RouteLedgerReplay(data: try ProfileFileIO.read(journal))
        guard replay.permitsAutomaticRecovery, replay.installed == [owned] else { throw RouteExecutionError.journalFailure }
        var deleted: [String] = []
        let executor = RouteExecutor(journal: journal, run: { executable, args in
            guard executable == "/sbin/route" else { throw RouteExecutionError.disallowedExecutable }
            if args.contains("get") { return "destination: 198.51.100.0\nmask: 255.255.255.0\ngateway: 192.0.2.1\ninterface: en0" }
            guard args.contains("delete") else { throw RouteExecutionError.disallowedExecutable }
            deleted.append(args[args.firstIndex(of: "-net")! + 1])
            return ""
        })
        let archives = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("routes-recovery-original-") }
        guard executor.installed.isEmpty, deleted == [owned.prefix.description],
              !FileManager.default.fileExists(atPath: journal.path), archives.count == 1,
              try ProfileFileIO.read(archives[0]) == original else { throw RouteExecutionError.journalFailure }
        // IPv6 uses the same absence proof, including foreign interface routes.
        let route6 = IPv6RouteTarget(try IPv6CIDR("2001:db8:42::/48"), .interface("utun9"))
        let mutation6 = IPv6RouteMutation(action: .add, route: route6)
        var bytes6 = try JSONEncoder().encode(IPv6RouteLedgerEvent(phase: .begun, ipv6Mutation: mutation6))
        bytes6.append(10)
        let table6 = "Internet6:\nDestination Gateway Flags Netif\ndefault fe80::1%en0 UGc en0\n"
        try reject(bytes6, table: table6 + "2001:db8:42::/48 link#9 UcI utun9\n")
        try ProfileFileIO.write(bytes6, to: journal)
        try RouteJournalRecovery.reconcileAbsentAdds(journal, run: { _, _ in table6 })
        guard RouteLedgerReplay(data: try ProfileFileIO.read(journal)).permitsAutomaticRecovery else {
            throw RouteExecutionError.journalFailure
        }
        print("PASS: absent IPv4/IPv6 add intents reconcile with original archives; committed ownership is verified; present, malformed and unknown evidence is retained.")
    }
}
#endif
