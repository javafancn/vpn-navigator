#if DEBUG
import Foundation
import VPNNavigatorCore

/// Pure planning: no routes, network requests or privileged state.
enum RulePlanningSelfTest {
    static func run() throws {
        let country = try IPv6RuleSet(text: "240e:1234::/32\n240e:1234:1::/48\n240e:1235::/48\n240e:1236::/48")
        let custom = try CustomRuleSet([.init(cidr: "240e:1234:2::/48", action: .vpn),
                                        .init(cidr: "2606:4700::/32", action: .direct)])
        let result = try custom.directPrefixes6(country: country, local: [], endpoint: nil,
            protectedVPN: [IPv6CIDR("240e:1234:1::53/128")])
        for (address, expected) in [("240e:1234:1::52", true), ("240e:1234:1::53", false),
            ("240e:1234:2::1", false), ("240e:1235::1", true), ("240e:1236::1", true),
            ("2606:4700::1111", true), ("240e:1237::1", false)] {
            guard result.contains(where: { $0.contains(address) }) == expected else { throw Failure.check }
        }
        // Compare membership to the boolean policy across adjacent /128s,
        // including a cut at the low and high end of a /120.
        let small = try IPv6RuleSet(text: "240e:42::/120\n240e:42::40/122")
        let cuts = try [IPv6CIDR("240e:42::/128"), IPv6CIDR("240e:42::ff/128"), IPv6CIDR("240e:42::80/122")]
        let remainder = try CustomRuleSet.empty.directPrefixes6(country: small, local: [], endpoint: nil, protectedVPN: cuts)
        for value in 0..<256 {
            let address = "240e:42::" + String(value, radix: 16)
            guard remainder.contains(where: { $0.contains(address) }) == !cuts.contains(where: { $0.contains(address) }) else { throw Failure.check }
        }
        let rules = try IPv6RuleSet(text: (0..<4096).map { "240e:\(String($0, radix: 16))::/48" }.joined(separator: "\n"))
        let started = ProcessInfo.processInfo.systemUptime
        let planned = try CustomRuleSet.empty.directPrefixes6(country: rules, local: [], endpoint: nil)
        let seconds = ProcessInfo.processInfo.systemUptime - started
        guard planned == rules.routes, seconds < 2 else { throw Failure.check }
        print("METRIC: 4096 IPv6 prefix planning seconds=\(String(format: "%.6f", seconds))")
        print("PASS: IPv6 nested-prefix removal, disjoint coverage, host/VPN cuts and bounded large-plan latency; pure planning only.")
    }
    enum Failure: Error { case check }
}
#endif
