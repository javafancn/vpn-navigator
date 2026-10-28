import Foundation
import Darwin
import VPNNavigatorCore

/// Reconcile only add intents whose exact prefixes are conclusively absent.
/// The caller must first establish that no previous OpenVPN child is alive.
enum RouteJournalRecovery {
    static func validate(_ journal: URL, run: (String, [String]) throws -> String = RouteExecutor.command) throws -> (Data, RouteLedgerReplay)? {
        var info = stat()
        guard lstat(journal.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw RouteExecutionError.ambiguousJournal
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else {
            throw RouteExecutionError.ambiguousJournal
        }
        let bytes = try ProfileFileIO.read(journal, maximumBytes: 16_000_000)
        let replay = RouteLedgerReplay(data: bytes)
        guard !replay.malformed else { throw RouteExecutionError.ambiguousJournal }
        let routes = replay.installed + replay.uncertain.map(\.route)
        let routes6 = replay.installed6 + replay.uncertain6.map(\.route)
        guard routes.count + routes6.count <= 60_000,
              routes.allSatisfy({ route in
                  (0...32).contains(route.prefix.prefix) &&
                  (try? IPv4CIDR(route.prefix.description)) == route.prefix && valid(route.destination)
              }),
              routes6.allSatisfy({ route in
                  (0...128).contains(route.prefix.prefix) && route.prefix.network.count == 16 &&
                  (try? IPv6CIDR(route.prefix.description)) == route.prefix && valid(route.destination)
              }) else { throw RouteExecutionError.ambiguousJournal }
        if replay.permitsAutomaticRecovery { return (bytes, replay) }
        guard replay.uncertain.allSatisfy({ $0.action == .add }),
              replay.uncertain6.allSatisfy({ $0.action == .add }) else { throw RouteExecutionError.ambiguousJournal }
        if !replay.uncertain.isEmpty {
            let table = try run("/usr/sbin/netstat", ["-rn", "-f", "inet"])
            guard replay.uncertain.allSatisfy({ RoutePrefixPresence.ipv4($0.route.prefix, table: table) == .absent }) else {
                throw RouteExecutionError.ambiguousJournal
            }
        }
        if !replay.uncertain6.isEmpty {
            let table = try run("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
            guard replay.uncertain6.allSatisfy({ RoutePrefixPresence.ipv6($0.route.prefix, table: table) == .absent }) else {
                throw RouteExecutionError.ambiguousJournal
            }
        }
        return (bytes, replay)
    }

    static func reconcileAbsentAdds(_ journal: URL, run: (String, [String]) throws -> String = RouteExecutor.command) throws {
        guard let (original, replay) = try validate(journal, run: run),
              !replay.permitsAutomaticRecovery else { return }
        var compact = Data()
        func append<T: Encodable>(_ event: T) throws {
            compact.append(try JSONEncoder().encode(event))
            compact.append(10)
        }
        for route in replay.installed {
            let mutation = RouteMutation(action: .add, route: route)
            try append(RouteLedgerEvent(phase: .begun, mutation: mutation))
            try append(RouteLedgerEvent(phase: .committed, mutation: mutation))
        }
        for route in replay.installed6 {
            let mutation = IPv6RouteMutation(action: .add, route: route)
            try append(IPv6RouteLedgerEvent(phase: .begun, ipv6Mutation: mutation))
            try append(IPv6RouteLedgerEvent(phase: .committed, ipv6Mutation: mutation))
        }
        let checked = RouteLedgerReplay(data: compact)
        guard checked.permitsAutomaticRecovery, checked.installed == replay.installed,
              checked.installed6 == replay.installed6 else { throw RouteExecutionError.ambiguousJournal }
        let archive = journal.deletingLastPathComponent().appendingPathComponent("routes-recovery-original-" + UUID().uuidString + ".jsonl")
        try ProfileFileIO.write(original, to: archive)
        try ProfileFileIO.write(compact, to: journal, beforeCommit: {
            guard try ProfileFileIO.read(journal, maximumBytes: 16_000_000) == original else {
                throw RouteExecutionError.ambiguousJournal
            }
        })
    }

    private static func valid(_ destination: RouteTarget.Destination) -> Bool {
        switch destination {
        case .interface(let name): return DNSRecoveryPolicy.validTunnel(name)
        case .viaGateway(let gateway):
            if IPv4CIDR.parseAddress(gateway) != nil || IPv6CIDR.parseAddress(gateway) != nil { return true }
            let parts = gateway.split(separator: "%", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, IPv6CIDR.parseAddress(parts[0]) != nil else { return false }
            return parts[1].range(of: #"^(en|bridge|pdp_ip)[0-9]+$"#, options: .regularExpression) != nil
        }
    }
}
