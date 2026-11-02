#if DEBUG
import Foundation
import VPNNavigatorCore

enum RouteCompactionSelfTest {
    static func run() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("route-compaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = folder.appendingPathComponent("routes.journal")
        let routes = try (0..<128).map { RouteTarget(try IPv4CIDR("11.0.\($0).0/24"), .viaGateway("192.168.1.1")) }
        let routes6 = try (0..<16).map { IPv6RouteTarget(try IPv6CIDR("240e:\(String($0, radix: 16))::/32"), .viaGateway("2001:db8::1")) }
        var live: [String: RouteTarget] = [:], live6: [String: IPv6RouteTarget] = [:]
        var failAdd = false
        var failDeletePrefix: String?
        let run: (String, [String]) throws -> String = { command, args in
            let v6 = args.contains("inet6") || args.contains("-inet6")
            if command == "/usr/sbin/netstat" { return (v6 ? Array(live6.keys) : Array(live.keys)).joined(separator: "\n") }
            guard let prefix = args.first(where: { $0.contains("/") }) else { throw Failure.check }
            if args.contains("get") {
                if v6, let route = live6[prefix] { return "destination: \(route.prefix.address)\nmask: \(route.prefix.netmask)\ngateway: 2001:db8::1\ninterface: en0" }
                if let route = live[prefix] { return "destination: \(IPv4CIDR.parseAddressString(route.prefix.network))\nmask: \(route.prefix.netmask)\ngateway: 192.168.1.1\ninterface: en0" }
                throw Failure.check
            }
            if args.contains("add") {
                if failAdd { throw Failure.check }
                if v6 { live6[prefix] = routes6.first { $0.prefix.description == prefix } }
                else { live[prefix] = routes.first { $0.prefix.description == prefix } }
            } else if args.contains("delete") {
                if prefix == failDeletePrefix { throw Failure.check }
                if v6 { live6.removeValue(forKey: prefix) } else { live.removeValue(forKey: prefix) }
            } else { throw Failure.check }
            return ""
        }
        let executor = RouteExecutor(journal: journal, run: run, compactionInterval: 8192)
        var checkpointSeen = false
        for _ in 0..<12 {
            try executor.apply(routes); try executor.applyIPv6(routes6)
            let bytes = try Data(contentsOf: journal), replay = RouteLedgerReplay(data: bytes)
            checkpointSeen = checkpointSeen || String(decoding: bytes, as: UTF8.self).contains("vpnnav-route-checkpoint")
            guard bytes.count < 80_000, replay.permitsAutomaticRecovery,
                  replay.installed == executor.installed, replay.installed6 == executor.installed6 else { throw Failure.check }
            try executor.refreshDirectRoutes(added: [], removed: routes)
            try executor.refreshIPv6(added: [], removed: routes6)
            let empty = RouteLedgerReplay(data: try Data(contentsOf: journal))
            guard empty.permitsAutomaticRecovery, empty.installed.isEmpty, empty.installed6.isEmpty else { throw Failure.check }
        }
        guard checkpointSeen, live.isEmpty, live6.isEmpty else { throw Failure.check }
        // Incomplete mutations must retain their exact bytes, including when
        // a checkpoint preceded the failed kernel operation.
        failAdd = true
        do { try executor.apply(routes); throw Failure.unexpectedSuccess } catch Failure.check {}
        let uncertain = try Data(contentsOf: journal)
        guard !RouteLedgerReplay(data: uncertain).permitsAutomaticRecovery else { throw Failure.check }
        executor.rollback()
        guard try Data(contentsOf: journal) == uncertain else { throw Failure.check }
        // Old JSON-array journals have no terminal newline. Recovery must not
        // append the next intent directly after ']' and corrupt its own log.
        let legacy = folder.appendingPathComponent("legacy.journal")
        let oldRoutes = Array(routes.prefix(2))
        try JSONEncoder().encode(oldRoutes).write(to: legacy)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacy.path)
        for route in oldRoutes { live[route.prefix.description] = route }
        let recovered = RouteExecutor(journal: legacy, run: run)
        guard recovered.installed.isEmpty, live.isEmpty,
              !FileManager.default.fileExists(atPath: legacy.path) else { throw Failure.check }
        let partial = folder.appendingPathComponent("partial-legacy.journal")
        try JSONEncoder().encode(oldRoutes).write(to: partial)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        for route in oldRoutes { live[route.prefix.description] = route }
        failDeletePrefix = oldRoutes[0].prefix.description
        let interrupted = RouteExecutor(journal: partial, run: run)
        let evidence = try Data(contentsOf: partial), replay = RouteLedgerReplay(data: evidence)
        guard interrupted.installed == [oldRoutes[0]], !replay.malformed,
              !replay.permitsAutomaticRecovery, replay.uncertain.count == 1 else { throw Failure.check }
        interrupted.rollback()
        guard try Data(contentsOf: partial) == evidence else { throw Failure.check }
        print("PASS: repeated dual-stack route changes compact atomically, preserve exact ownership/order and keep ambiguous mutations intact; injected OS only.")
        print("PASS: legacy journals without trailing newline recover without creating malformed appended records.")
    }
    enum Failure: Error { case check, unexpectedSuccess }
}
#endif
