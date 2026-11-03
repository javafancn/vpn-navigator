#if DEBUG
import Foundation
import VPNNavigatorCore

/// Pure policy/wire checks: no routes, firewall, system DNS or public traffic.
enum NetworkLatencySelfTest {
    static func run() throws {
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw Failure.check(label) }
        }
        func query(_ name: String = "cache.example", type: UInt8 = 1) -> Data {
            var q = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
            for label in name.split(separator: ".") { q.append(UInt8(label.utf8.count)); q.append(contentsOf: label.utf8) }
            q.append(contentsOf: [0, 0, type, 0, 1]); return q
        }
        func answer(_ q: Data, ttl: UInt8 = 60) -> Data {
            var a = q; a[2] = 0x81; a[3] = 0x80; a[7] = 1
            a.append(contentsOf: [0xc0, 12, 0, 1, 0, 1, 0, 0, 0, ttl, 0, 4, 192, 0, 2, 1]); return a
        }
        let q = query(), a = answer(q), key = DNSAnswerCache.key(for: q, tcp: false)!
        var cache = DNSAnswerCache(capacity: 2)
        cache.insert(a, for: key, request: q, now: 10)
        var changedID = q; changedID[0] = 0xab; changedID[1] = 0xcd
        try check(DNSAnswerCache.key(for: changedID, tcp: false) == key, "ID-independent key")
        let hit = cache.answer(for: key, request: changedID, now: 12)!
        try check(hit[0] == 0xab && hit[1] == 0xcd && hit[q.count + 9] == 58, "ID restore / TTL aging")
        try check(cache.answer(for: key, request: q, now: 70) == nil, "TTL expiry")
        try check(DNSAnswerCache.key(for: q, tcp: true) != key, "TCP/UDP isolation")
        var cd = q; cd[3] = 0x10
        try check(DNSAnswerCache.key(for: cd, tcp: false) != key, "DNSSEC flags isolation")
        var opt = a; opt[11] = 1
        opt.append(contentsOf: [0, 0, 41, 4, 208, 0, 0, 128, 0, 0, 0])
        cache.insert(opt, for: key, request: q, now: 100)
        try check(cache.answer(for: key, request: q, now: 101)?.suffix(11) == opt.suffix(11), "OPT flags never aged as TTL")
        _ = cache.answer(for: key, request: q, now: 160)
        for flag in [UInt8(2), 3, 5] {
            var bad = a; bad[3] = 0x80 | flag
            cache.insert(bad, for: key, request: q, now: 200)
            try check(cache.answer(for: key, request: q, now: 200) == nil, "errors not cached")
        }
        var truncated = a; truncated[2] |= 2
        var signed = a; signed[q.count + 3] = 46
        var invalidPointer = a; invalidPointer[q.count] = 0xff; invalidPointer[q.count + 1] = 0xff
        for bad in [answer(q, ttl: 0), truncated, signed, invalidPointer, Data(a.dropLast())] {
            cache.insert(bad, for: key, request: q, now: 200)
            try check(cache.answer(for: key, request: q, now: 200) == nil, "uncacheable / malformed reply")
        }
        let q2 = query("two.example"), q3 = query("three.example")
        let key2 = DNSAnswerCache.key(for: q2, tcp: false)!, key3 = DNSAnswerCache.key(for: q3, tcp: false)!
        cache.insert(a, for: key, request: q, now: 300)
        cache.insert(answer(q2), for: key2, request: q2, now: 300)
        _ = cache.answer(for: key, request: q, now: 301)
        cache.insert(answer(q3), for: key3, request: q3, now: 301)
        try check(cache.answer(for: key2, request: q2, now: 301) == nil, "LRU capacity")
        var tiny = DNSAnswerCache(maximumBytes: 1)
        tiny.insert(a, for: key, request: q, now: 0)
        try check(tiny.answer(for: key, request: q, now: 0) == nil, "byte limit")

        let aaaa = query(type: 28), nodata = DNSQuestion(aaaa)!.noData(for: aaaa)
        try check(nodata[3] & 15 == 0 && nodata[6...11].allSatisfy { $0 == 0 }
            && DNSQuestion(aaaa)!.accepts(nodata, request: aaaa), "unavailable family NODATA")
        try check(SplitDNSPolicy.domesticServers(path4: true, path6: false, protectedVPN: ["10.8.0.53"],
            preferred: ["127.0.0.1", "::1", "10.8.0.53", "192.168.1.1"]) == ["192.168.1.1", "223.5.5.5"], "physical resolver priority / exclusions")
        let plan = try DualStackRoutePlan.build(endpoint: "8.8.4.4", tunnel: "utun4", has4: true, has6: false,
            path4: PhysicalIPPath(gateway: "192.168.1.1", interface: "en0"), path6: nil,
            local4: [IPv4CIDR("192.168.1.0/24")], local6: [], mode: .chinaDirect,
            country4: RuleSet(text: "11.0.0.0/8"), country6: nil, custom: .empty,
            dnsServers: ["1.1.1.1"], directDNSServers: ["192.168.1.1"])
        try check(plan.physicalDNS == ["192.168.1.1"] && !plan.direct4.contains { $0.prefix.contains(IPv4CIDR.parseAddress("192.168.1.1")!) }, "LAN resolver remains on-link")
        let policy = try LeakGuardPolicy(physical: "en0", endpoint: "8.8.4.4", port: 1194, transport: .udp,
            local: [IPv4CIDR("192.168.1.0/24")], country: [])
        try check(try policy.rules(tunnel: "utun4").contains("block return out quick inet6"), "IPv6 immediate reject")

        let profile = "client\ndev tun\nproto udp\nremote one.example 1194\nremote two.example 443 tcp6-client\nremote one.example 1194\n<ca>\nremote ignored.example 443\n</ca>"
        var lookups = 0
        let candidates = try GuardEndpoint.resolveCandidates(profile) { host in
            lookups += 1
            return host == "one.example" ? ["8.8.8.8", "8.8.4.4"] : ["9.9.9.9", "2606:4700::1111"]
        }
        try check(lookups == 2 && candidates.map(\.address) == ["8.8.8.8", "2606:4700::1111", "8.8.4.4"], "multiple remote / address failover / lookup deduplication")
        let pinned = try candidates[1].endpoint.pinnedProfile(profile, address: candidates[1].address)
        try check(pinned.contains("remote 2606:4700::1111 443") && pinned.contains("proto tcp6-client")
            && pinned.contains("remote ignored.example 443"), "per-retry pin / inline preservation")
        try check(OpenVPNCommand.latencyArguments(for: pinned) == ["--socket-flags", "TCP_NODELAY"]
            && OpenVPNCommand.latencyArguments(for: profile).isEmpty, "TCP-only latency tuning")
        try check(OpenVPNCommand.candidateTimeoutArguments(for: profile, remainingSeconds: 20, candidateCount: 3) == ["--server-poll-timeout", "6"]
            && OpenVPNCommand.candidateTimeoutArguments(for: profile + "\nconnect-timeout 25", remainingSeconds: 20, candidateCount: 3).isEmpty,
            "bounded alternate endpoint wait / explicit timeout preservation")
        print("PASS: DNS TTL aging/expiry/LRU/byte limits, ID/transport/flags isolation, errors/truncation/signatures excluded, IPv6 NODATA/reject, physical/LAN DNS policy, multi-remote numeric candidates and TCP latency tuning.")
    }
    enum Failure: Error { case check(String) }
}
#endif
