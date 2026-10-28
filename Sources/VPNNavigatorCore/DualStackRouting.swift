import Foundation

public enum IPAddress {
    public static func canonical(_ text: String) -> String? {
        if let value = IPv4CIDR.parseAddress(text) { return IPv4CIDR.parseAddressString(value) }
        return IPv6CIDR.parseAddress(text).map(IPv6CIDR.addressString)
    }
    public static func isIPv6(_ text: String) -> Bool { IPv6CIDR.parseAddress(text) != nil }
    public static func gateway6(_ text: String, interface: String) -> String? {
        let parts = text.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2, let base = parts.first, let bytes = IPv6CIDR.parseAddress(String(base)),
              bytes.contains(where: { $0 != 0 }), bytes.first != 255 else { return nil }
        if parts.count == 2, String(parts[1]) != interface { return nil }
        let canonical = IPv6CIDR.addressString(bytes)
        return canonical + (canonical.hasPrefix("fe80:") ? "%" + interface : "")
    }
}
public enum TunnelIPStack: String, Codable, Sendable { case ipv4, ipv6, dual
    public var title: String { switch self { case .ipv4: return L10n.text("IPv4 · IPv6 未建立"); case .ipv6: return L10n.text("IPv6 · IPv4 未建立"); case .dual: return L10n.text("IPv4＋IPv6 双栈") } }
}
public struct RoutingRuleBundle: Codable, Sendable {
    public let ipv4: String
    public let ipv6: String?
    public init(ipv4: String, ipv6: String? = nil) { self.ipv4 = ipv4; self.ipv6 = ipv6 }
    public var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    public static func decoded(_ text: String) throws -> Self {
        guard text.utf8.count <= 4_100_000 else { throw RuleError.tooLarge }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return .init(ipv4: text) }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard value.ipv4.utf8.count <= 2_000_000, (value.ipv6?.utf8.count ?? 0) <= 2_000_000 else { throw RuleError.tooLarge }
        return value
    }
}
public struct IPv6RouteTarget: Hashable, Codable, Sendable {
    public let prefix: IPv6CIDR
    public let destination: RouteTarget.Destination
    public init(_ prefix: IPv6CIDR, _ destination: RouteTarget.Destination) { self.prefix = prefix; self.destination = destination }
    public func arguments(adding: Bool) -> [String] {
        let base = ["-n", adding ? "add" : "delete", "-inet6", "-net", prefix.description]
        switch destination { case .viaGateway(let value): return base + [value]; case .interface(let value): return base + ["-interface", value] }
    }
}
public struct ObservedIPv6Route: Sendable {
    private let fields: [String: String]
    public init(commandOutput: String) {
        fields = Dictionary(commandOutput.components(separatedBy: .newlines).compactMap { row -> (String, String)? in
            let parts = row.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }; return (String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { first, _ in first })
    }
    public func isExactly(_ target: IPv6RouteTarget) -> Bool {
        guard let dest = fields["destination"], IPv6CIDR.parseAddress(dest) == target.prefix.network else { return false }
        if let mask = fields["mask"] {
            guard mask == "/\(target.prefix.prefix)" || IPv6CIDR.parseAddress(mask) == IPv6CIDR.parseAddress(target.prefix.netmask) else { return false }
        } else if target.prefix.prefix != 128 { return false }
        switch target.destination {
        case .viaGateway(let gateway):
            guard let iface = fields["interface"], let actual = fields["gateway"] else { return false }
            guard let expected = IPAddress.gateway6(gateway, interface: iface), let found = IPAddress.gateway6(actual, interface: iface) else { return false }
            return found == expected
        case .interface(let interface): return fields["interface"] == interface
        }
    }
}
public enum LocalIPv6Networks {
    public static func parse(netstat: String, physicalInterface: String) -> [IPv6CIDR] {
        var found = Set<IPv6CIDR>()
        for line in netstat.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 4, parts[3] == physicalInterface, parts[1].hasPrefix("link#"),
                  let prefix = try? IPv6CIDR(parts[0]), prefix.prefix >= 3,
                  !prefix.address.hasPrefix("fe80:"), !prefix.address.hasPrefix("ff") else { continue }
            found.insert(prefix)
        }
        return found.sorted()
    }
}
public struct PhysicalIPPath: Equatable, Sendable {
    public let gateway: String
    public let interface: String
    public init(gateway: String, interface: String) throws {
        if DNSRecoveryPolicy.validTunnel(interface) { throw RoutePlanningError.competingTunnel }
        guard LeakGuardPolicy.validPhysical(interface), (IPv4CIDR.parseAddress(gateway).map { $0 != 0 && $0 >> 24 != 127 && $0 >> 24 < 224 } == true) || IPAddress.gateway6(gateway, interface: interface) != nil else { throw RoutePlanningError.invalidGateway }
        self.gateway = IPAddress.gateway6(gateway, interface: interface) ?? gateway; self.interface = interface
    }
}
public struct DualStackRoutePlan: Sendable {
    public let endpoint4: RouteTarget?
    public let endpoint6: IPv6RouteTarget?
    public let direct4: [RouteTarget]
    public let direct6: [IPv6RouteTarget]
    public let defaults4: [RouteTarget]
    public let defaults6: [IPv6RouteTarget]
    public let path4: PhysicalIPPath?
    public let path6: PhysicalIPPath?
    public let tunnel: String
    public let endpoint: String
    public let local4: [IPv4CIDR]
    public let local6: [IPv6CIDR]
    public var ipv4: [RouteTarget] { (endpoint4.map { [$0] } ?? []) + direct4 + defaults4 }
    public var ipv6: [IPv6RouteTarget] { (endpoint6.map { [$0] } ?? []) + direct6 + defaults6 }
    public var stack: TunnelIPStack { defaults4.isEmpty ? .ipv6 : defaults6.isEmpty ? .ipv4 : .dual }
    public static func build(endpoint: String, tunnel: String, has4: Bool, has6: Bool,
        path4: PhysicalIPPath?, path6: PhysicalIPPath?, local4: [IPv4CIDR], local6: [IPv6CIDR],
        mode: RoutingMode, country4: RuleSet?, country6: IPv6RuleSet?, custom: CustomRuleSet) throws -> Self {
        guard DNSRecoveryPolicy.validTunnel(tunnel), let endpoint = IPAddress.canonical(endpoint), has4 || has6 else { throw DualStackError.missingTunnel }
        if let ip4 = IPv4CIDR.parseAddress(endpoint), (ip4 >> 24 == 0 || ip4 >> 24 == 127 || ip4 >> 24 >= 224) { throw RoutePlanningError.blockedServerAddress }
        if let ip6 = IPv6CIDR.parseAddress(endpoint), ip6 == [UInt8](repeating: 0, count: 16) || endpoint == "::1" || ip6.first == 255 || endpoint.hasPrefix("fe80:") || endpoint.hasPrefix("::ffff:") { throw RoutePlanningError.blockedServerAddress }
        let endpoint4: RouteTarget?, endpoint6: IPv6RouteTarget?
        if IPAddress.isIPv6(endpoint) {
            guard let path6 else { throw DualStackError.missingPhysical }
            endpoint4 = nil; endpoint6 = IPv6RouteTarget(try IPv6CIDR(endpoint + "/128"), .viaGateway(path6.gateway))
        } else {
            guard let path4 else { throw DualStackError.missingPhysical }
            endpoint4 = RouteTarget(try IPv4CIDR(endpoint + "/32"), .viaGateway(path4.gateway)); endpoint6 = nil
        }
        if mode == .chinaDirect && has4 && country4 == nil { throw CompilerError.missingRules }
        if mode == .chinaDirect && has6 && country6 == nil { throw DualStackError.missingRules }
        if !has4 && custom.active.contains(where: { !$0.cidr.contains(":") }) || !has6 && custom.active.contains(where: { $0.cidr.contains(":") }) { throw DualStackError.missingTunnel }
        let prefixes4 = try custom.directPrefixes(country: has4 && mode == .chinaDirect ? country4 : nil, local: local4, endpoint: endpoint)
        let prefixes6 = try custom.directPrefixes6(country: has6 && mode == .chinaDirect ? country6 : nil, local: local6, endpoint: endpoint)
        guard prefixes4.isEmpty || path4 != nil, prefixes6.isEmpty || path6 != nil else { throw DualStackError.missingPhysical }
        return try .init(endpoint4: endpoint4, endpoint6: endpoint6,
            direct4: prefixes4.map { RouteTarget($0, .viaGateway(path4!.gateway)) },
            direct6: prefixes6.map { IPv6RouteTarget($0, .viaGateway(path6!.gateway)) },
            defaults4: has4 ? [RouteTarget(IPv4CIDR("0.0.0.0/1"), .interface(tunnel)), RouteTarget(IPv4CIDR("128.0.0.0/1"), .interface(tunnel))] : [],
            defaults6: has6 ? [IPv6RouteTarget(IPv6CIDR("::/1"), .interface(tunnel)), IPv6RouteTarget(IPv6CIDR("8000::/1"), .interface(tunnel))] : [],
            path4: path4, path6: path6, tunnel: tunnel, endpoint: endpoint, local4: local4, local6: local6)
    }
}
public enum DualStackError: Error, LocalizedError {
    case missingTunnel, missingPhysical, missingRules, requireDualStack, unsafeFallback
    public var errorDescription: String? {
        switch self {
        case .missingTunnel: return L10n.text("服务器未提供所需的隧道地址，无法应用对应地址族的自定义规则。")
        case .missingPhysical: return L10n.text("没有可核验的物理出口，无法应用端点或直连规则。")
        case .missingRules: return L10n.text("双栈规则路由需要有效的中国 IPv6 规则，请先更新 IPv6 规则。")
        case .requireDualStack: return L10n.text("已要求双栈，但服务器没有同时分配 IPv4 和 IPv6 隧道地址。")
        case .unsafeFallback: return L10n.text("服务器未承载的地址族仍有系统出口；请启用断线保护或使用支持双栈的服务器。")
        }
    }
}
