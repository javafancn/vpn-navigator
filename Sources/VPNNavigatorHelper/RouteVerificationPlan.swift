import Foundation
import VPNNavigatorCore

/// Compile representative probes once per policy, not once per watchdog tick.
struct RouteVerificationPlan {
    private struct Probe: Hashable { let ip: String; let vpn: Bool }
    private let plan: DualStackRoutePlan
    private let probes: [Probe]
    private let custom: [Probe]
    private let sampledCustom: [Probe]
    init(plan: DualStackRoutePlan, custom: CustomRuleSet) throws {
        self.plan = plan
        var values = plan.physicalDNS.map { Probe(ip: $0, vpn: false) }
        if let route = plan.direct4.first { values.append(.init(ip: IPv4CIDR.parseAddressString(route.prefix.network), vpn: false)) }
        if let route = plan.direct6.first { values.append(.init(ip: route.prefix.address, vpn: false)) }
        if !plan.defaults4.isEmpty, let ip = ["8.8.8.8", "1.1.1.1", "9.9.9.9", "208.67.222.222"].first(where: { ip in
            let address = IPv4CIDR.parseAddress(ip)!
            return ip != plan.endpoint && !plan.direct4.contains { $0.prefix.contains(address) } && !plan.local4.contains { $0.contains(address) }
        }) { values.append(.init(ip: ip, vpn: true)) }
        if !plan.defaults6.isEmpty, let ip = ["2606:4700:4700::1111", "2001:4860:4860::8888", "2620:fe::fe"].first(where: { ip in
            ip != plan.endpoint && !plan.direct6.contains { $0.prefix.contains(ip) } && !plan.local6.contains { $0.contains(ip) }
        }) { values.append(.init(ip: ip, vpn: true)) }
        var seen = Set<Probe>()
        probes = values.filter { seen.insert($0).inserted }
        func probe(_ rule: CustomRouteRule) throws -> Probe {
            let ip = rule.cidr.contains(":") ? try CustomRuleSet.prefix6(rule.cidr).address : IPv4CIDR.parseAddressString(try CustomRuleSet.prefix(rule.cidr).network)
            let protected = plan.dns4.contains { $0.prefix.contains(IPv4CIDR.parseAddress(ip) ?? 0) } || plan.dns6.contains { $0.prefix.contains(ip) }
            return .init(ip: ip, vpn: protected || (rule.action == .vpn && !plan.physicalDNS.contains(ip)))
        }
        self.custom = try custom.active.map(probe)
        sampledCustom = try [false, true].flatMap { v6 in
            CustomRouteAction.allCases.compactMap { action in custom.active.first { $0.action == action && $0.cidr.contains(":") == v6 } }
        }.map(probe)
    }
    func verify(reader: KernelRouteReader, allCustom: Bool = false, check: () throws -> Void = {}) throws {
        for route in (plan.endpoint4.map { [$0] } ?? []) + plan.dns4 + plan.defaults4 {
            try check()
            guard try reader.observe(route).isExactly(route) else { throw TunnelError.routeVerificationFailed }
        }
        for route in (plan.endpoint6.map { [$0] } ?? []) + plan.dns6 + plan.defaults6 {
            try check()
            guard try reader.observe(route).isExactly(route) else { throw TunnelError.routeVerificationFailed }
        }
        for probe in probes + (allCustom ? custom : sampledCustom) {
            try check()
            let actual = try reader.lookup(probe.ip)
            if probe.vpn {
                guard actual.interface == plan.tunnel else { throw TunnelError.routeVerificationFailed }
            } else {
                let v6 = IPAddress.isIPv6(probe.ip)
                let local = v6 ? plan.local6.contains { $0.contains(probe.ip) }
                    : plan.local4.contains { $0.contains(IPv4CIDR.parseAddress(probe.ip) ?? 0) }
                guard let path = v6 ? plan.path6 : plan.path4, actual.interface == path.interface,
                      local || (v6 ? IPAddress.gateway6(actual.gateway, interface: actual.interface) == path.gateway : actual.gateway == path.gateway) else {
                    throw TunnelError.routeVerificationFailed
                }
            }
        }
    }
}
