#if DEBUG
import Foundation
import VPNNavigatorCore

/// Review counterexamples, without system DNS, routes, PF or public requests.
enum ReviewRegressionSelfTest {
    static func run(seeds: URL) async throws {
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw Failure.check(label) }
        }
        let lan4 = [try IPv4CIDR("192.168.1.0/24")], lan6 = [try IPv6CIDR("fd12::/64")]
        let china4 = try RuleSet(text: "114.114.114.0/24"), china6 = try IPv6RuleSet(text: "240e::/20")
        func select(_ preferred: [String], local4: [IPv4CIDR] = [], local6: [IPv6CIDR] = []) -> [String] {
            SplitDNSPolicy.domesticServers(path4: true, path6: true, protectedVPN: ["10.8.0.1", "8.8.4.4"],
                preferred: preferred, local4: local4, local6: local6, country4: china4, country6: china6)
        }
        try check(select(["8.8.8.8", "1.1.1.1", "9.9.9.9", "2606:4700::1111"]) == ["223.5.5.5", "223.6.6.6"], "foreign public DNS must not become a bypass")
        try check(select(["100.100.2.136", "198.18.0.2"]) == ["223.5.5.5", "223.6.6.6"], "off-link special-use DNS falls back")
        try check(select(["10.8.0.1", "8.8.4.4", "192.168.1.1", "114.114.114.114"], local4: lan4) == ["192.168.1.1", "114.114.114.114"], "private/CN resolvers retained; VPN and endpoint excluded")
        try check(select(["fd12::53", "240e::53"], local6: lan6) == ["fd12::53", "240e::53"], "ULA/CN IPv6 selection")
        let p4 = try PhysicalIPPath(gateway: "192.168.1.1", interface: "en0")
        let p6 = try PhysicalIPPath(gateway: "fe80::1%en0", interface: "en0")
        func plan(_ servers: [String], lan: [IPv4CIDR]) throws -> DualStackRoutePlan {
            try .build(endpoint: "8.8.4.4", tunnel: "utun4", has4: true, has6: false, path4: p4, path6: nil,
                local4: lan, local6: [], mode: .chinaDirect, country4: china4, country6: nil,
                custom: .empty, dnsServers: ["10.8.0.1"], directDNSServers: servers)
        }
        for address in ["8.8.8.8", "1.1.1.1", "100.100.2.136", "198.18.0.2"] {
            do { _ = try plan([address], lan: lan4); throw Failure.check("route builder accepted " + address) }
            catch CustomRouteError.invalidPrefix { }
        }
        for address in ["100.100.2.136", "198.18.0.2"] {
            let lan = lan4 + [try IPv4CIDR(address + "/24")]
            let servers = select([address], local4: lan)
            let value = try plan(servers, lan: lan)
            try check(!value.direct4.contains { $0.prefix.contains(IPv4CIDR.parseAddress(address)!) }, "on-link resolver has no gateway host route")
            _ = try LeakGuardPolicy(physical: "en0", endpoint: value.endpoint, port: 1194, transport: .udp,
                local: lan, country: [], managedDirect: value.direct4.map(\.prefix))
        }
        let safe = try plan(select(["8.8.8.8", "100.100.2.136"]), lan: lan4)
        try check(!safe.direct4.contains { $0.prefix.contains(IPv4CIDR.parseAddress("8.8.8.8")!) }, "foreign DNS has no physical route")
        _ = try LeakGuardPolicy(physical: "en0", endpoint: safe.endpoint, port: 1194, transport: .udp,
            local: lan4, country: [], managedDirect: safe.direct4.map(\.prefix))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-rules-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed4 = seeds.appendingPathComponent("china-ipv4.txt"), seed6 = seeds.appendingPathComponent("china-ipv6.txt")
        try await RoutingRuleUpdate.bootstrap(root: root, ipv4Seed: seed4, ipv6Seed: seed6)
        let initial = try await RoutingRuleUpdate.cached(root: root)
        try check((initial.ipv4?.routes.count ?? 0) >= 100 && (initial.ipv6?.routes.count ?? 0) >= 100, "fresh install has both country families")
        _ = try DualStackRoutePlan.build(endpoint: "8.8.4.4", tunnel: "utun4", has4: true, has6: true, path4: p4, path6: p6,
            local4: lan4, local6: lan6, mode: .chinaDirect, country4: initial.ipv4, country6: initial.ipv6, custom: .empty)
        // Existing families are never read from/replaced by the bundle again.
        try await RoutingRuleUpdate.bootstrap(root: root, ipv4Seed: root.appendingPathComponent("missing4"), ipv6Seed: root.appendingPathComponent("missing6"))
        let retained = try await RoutingRuleUpdate.cached(root: root)
        try check(retained.ipv4?.routes == initial.ipv4?.routes && retained.ipv6?.routes == initial.ipv6?.routes, "bootstrap preserves existing rule data")
        let partial = root.appendingPathComponent("partial")
        try await RoutingRuleUpdate.bootstrap(root: partial, ipv4Seed: seed4, ipv6Seed: nil)
        try await RoutingRuleUpdate.bootstrap(root: partial, ipv4Seed: nil, ipv6Seed: seed6)
        let completed = try await RoutingRuleUpdate.cached(root: partial)
        try check(completed.ipv4?.routes == initial.ipv4?.routes && completed.ipv6?.routes == initial.ipv6?.routes, "IPv4-only cache receives the IPv6 seed")
        let bad = root.appendingPathComponent("bad6.txt")
        try Data("::/0\n".utf8).write(to: bad)
        let failed = root.appendingPathComponent("failed")
        do {
            try await RoutingRuleUpdate.bootstrap(root: failed, ipv4Seed: seed4, ipv6Seed: bad)
            throw Failure.check("invalid IPv6 seed accepted")
        } catch is IPv6RuleError { }
        let unchanged = try await RoutingRuleUpdate.cached(root: failed)
        try check(unchanged.ipv4 == nil && unchanged.ipv6 == nil, "invalid seed cannot publish half a bundle")

        let base = "client\ndev tun\nremote fixture.example 1194\n<ca>\nfixture\n</ca>\n"
        for option in ["server-poll-timeout 1", "server-poll-timeout 3600", "socket-flags TCP_NODELAY", "connect-timeout 10"] {
            try check(try ProfileSafety.validate(base + option).text == base + option, "safe imported option preserved")
        }
        for option in ["server-poll-timeout 0", "server-poll-timeout -1", "server-poll-timeout 3601", "server-poll-timeout 10 extra", "socket-flags", "socket-flags TCP_NODELAY extra", "socket-flags SO_MARK"] {
            do { _ = try ProfileSafety.validate(base + option); throw Failure.check("unsafe option accepted") }
            catch is ProfileValidationError { }
        }
        print("PASS: foreign/off-link special DNS rejected in selection and planning; observed on-link special DNS survives PF; offline dual-stack bootstrap preserves existing rules; safe timeout/TCP_NODELAY options accepted with strict parameters.")
    }
    enum Failure: Error { case check(String) }
}
#endif
