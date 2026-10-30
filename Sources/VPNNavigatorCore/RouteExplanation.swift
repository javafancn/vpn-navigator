import Foundation

public enum ExplainedPath: String, Codable, Sendable { case direct, vpn, system, unknown, blocked
    public var title: String { switch self { case .direct: return L10n.text("直连"); case .vpn: return L10n.text("走 VPN"); case .system: return L10n.text("由原始配置和系统决定"); case .unknown: return L10n.text("无法判断"); case .blocked: return L10n.text("该地址族未建立隧道") } }
}
public struct RouteExplanation: Codable, Equatable, Sendable {
    public let ip: String
    public let path: ExplainedPath
    public let reason: String
    public let matchedPrefix: String?
    public init(ip: String, path: ExplainedPath, reason: String, matchedPrefix: String? = nil) {
        self.ip = ip; self.path = path; self.reason = reason; self.matchedPrefix = matchedPrefix
    }
    public static func decide(ip: String, mode: RoutingMode, country: RuleSet?, custom: CustomRuleSet,
                              local: [IPv4CIDR] = [], endpoint: String? = nil, effectiveDirect: [IPv4CIDR]? = nil,
                              country6: IPv6RuleSet? = nil, local6: [IPv6CIDR] = [], effectiveDirect6: [IPv6CIDR]? = nil,
                              available: Bool? = nil, directDNS: [String] = [], protectedDNS: [String] = []) throws -> Self {
        if mode == .chinaDirect, directDNS.contains(ip) {
            return .init(ip: ip, path: .direct, reason: L10n.text("国内域名解析专用直连 DNS，优先于地区和自定义规则。"), matchedPrefix: ip + (IPAddress.isIPv6(ip) ? "/128" : "/32"))
        }
        if mode != .original, protectedDNS.contains(ip) {
            return .init(ip: ip, path: .vpn, reason: L10n.text("DNS 解析通过 VPN，优先于地区和自定义直连规则。"), matchedPrefix: ip + (IPAddress.isIPv6(ip) ? "/128" : "/32"))
        }
        if IPAddress.isIPv6(ip) {
            if mode == .original { return .init(ip: ip, path: .system, reason: L10n.text("原始配置模式由 OpenVPN 和系统管理 IPv6 路径。")) }
            if ip == endpoint { return .init(ip: ip, path: .direct, reason: L10n.text("IPv6 服务器端点保留物理出口。"), matchedPrefix: ip + "/128") }
            if (try? CustomRuleSet.prefix6(ip)) == nil { return .init(ip: ip, path: .system, reason: L10n.text("IPv6 特殊地址由系统处理。")) }
            if let value = local6.filter({ $0.contains(ip) }).max(by: { $0.prefix < $1.prefix }) { return .init(ip: ip, path: .direct, reason: L10n.text("当前 IPv6 局域网保留直连。"), matchedPrefix: value.description) }
            if available == false { return .init(ip: ip, path: .blocked, reason: L10n.text("服务器未承载 IPv6；保护策略阻断非必要的 IPv6 物理出口。路由表本身不能证明防火墙是否放行。")) }
            if let rule = custom.active.first(where: { $0.cidr.contains(":") && (try? CustomRuleSet.prefix6($0.cidr).contains(ip)) == true }) {
                return .init(ip: ip, path: rule.action == .vpn ? .vpn : .direct, reason: L10n.text("命中本配置启用的 IPv6 自定义规则。"), matchedPrefix: rule.cidr)
            }
            if mode == .chinaDirect && country6 == nil { return .init(ip: ip, path: .unknown, reason: L10n.text("缺少可核验的中国 IPv6 规则。")) }
            let direct = try effectiveDirect6 ?? custom.directPrefixes6(country: mode == .chinaDirect ? country6 : nil, local: local6, endpoint: endpoint)
            if let value = direct.filter({ $0.contains(ip) }).max(by: { $0.prefix < $1.prefix }) { return .init(ip: ip, path: .direct, reason: L10n.text("命中已计算的中国 IPv6 直连前缀（APNIC 注册归属）。"), matchedPrefix: value.description) }
            return .init(ip: ip, path: .vpn, reason: L10n.text("未命中 IPv6 直连规则，使用 VPN 默认路由。"))
        }
        guard let address = IPv4CIDR.parseAddress(ip) else { throw CustomRouteError.invalidPrefix }
        if mode == .original { return .init(ip: ip, path: .system, reason: L10n.text("原始配置模式不应用应用内的地区或自定义规则。")) }
        if (try? CustomRuleSet.prefix(ip)) == nil { return .init(ip: ip, path: .system, reason: L10n.text("系统保留地址由系统路由处理，不套用应用内默认路径。")) }
        if ip == endpoint { return .init(ip: ip, path: .direct, reason: L10n.text("VPN 服务器端点保留物理出口，避免连接绕入自身隧道。"), matchedPrefix: ip + "/32") }
        if let prefix = local.filter({ $0.contains(address) }).max(by: { $0.prefix < $1.prefix }) {
            return .init(ip: ip, path: .direct, reason: L10n.text("当前局域网网段优先保留系统直连。"), matchedPrefix: prefix.description)
        }
        if available == false { return .init(ip: ip, path: .blocked, reason: L10n.text("服务器未承载 IPv4；由保护策略阻断非必要的 IPv4 物理出口。")) }
        if let rule = custom.active.first(where: { !$0.cidr.contains(":") && (try? CustomRuleSet.prefix($0.cidr).contains(address)) == true }) {
            return .init(ip: ip, path: rule.action == .direct ? .direct : .vpn,
                         reason: L10n.text("命中本配置启用的自定义规则。"), matchedPrefix: rule.cidr)
        }
        if mode == .chinaDirect && country == nil { return .init(ip: ip, path: .unknown, reason: L10n.text("未取得可核验的中国 IPv4 规则。")) }
        let direct = try effectiveDirect ?? custom.directPrefixes(country: mode == .chinaDirect ? country : nil, local: local, endpoint: endpoint)
        if let prefix = direct.filter({ $0.contains(address) }).max(by: { $0.prefix < $1.prefix }) {
            return .init(ip: ip, path: .direct, reason: L10n.text("命中已计算的中国 IPv4 直连前缀。"), matchedPrefix: prefix.description)
        }
        let skipped = mode == .chinaDirect && country?.contains(ip: ip) == true
        return .init(ip: ip, path: .vpn, reason: skipped ? L10n.text("地区前缀与本地网段冲突而未安装，使用 VPN 默认路由。") : L10n.text("未命中直连规则，使用 VPN 默认路由。"))
    }
}
public struct RouteLookupRequest: Codable, Equatable, Sendable {
    public let ip: String
    public let profileID: UUID
    public let attemptID: UUID
    public let revision: UUID?
    public let mode: RoutingMode
    public init(report: SessionReport, ip: String) throws {
        guard let address = IPAddress.canonical(ip), report.state == .connected, report.challenge == nil,
              let profileID = report.activeProfileID, let attemptID = report.attemptID,
              let mode = report.routingMode, mode == .original || report.routingRevision != nil else { throw RoutingModeSwitchError.stale }
        self.ip = address; self.profileID = profileID; self.attemptID = attemptID; revision = report.routingRevision; self.mode = mode
    }
    public func matches(_ report: SessionReport) -> Bool {
        report.state == .connected && report.challenge == nil && report.activeProfileID == profileID &&
        report.attemptID == attemptID && report.routingMode == mode && report.routingRevision == revision
    }
    public var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    public static func decoded(_ text: String) throws -> Self {
        guard text.utf8.count <= 2048, let data = text.data(using: .utf8) else { throw RoutingModeSwitchError.stale }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard let address = IPAddress.canonical(value.ip), address == value.ip,
              value.mode == .original || value.revision != nil else { throw RoutingModeSwitchError.stale }
        return value
    }
}
public struct RouteLookupResult: Codable, Equatable, Sendable {
    public let request: RouteLookupRequest
    public let decision: RouteExplanation
    public let expectedInterface: String?
    public let observedInterface: String
    public let observedGateway: String
    public let matchesExpected: Bool?
    public init(request: RouteLookupRequest, decision: RouteExplanation, expectedInterface: String?,
                observedInterface: String, observedGateway: String, matchesExpected: Bool?) {
        self.request = request; self.decision = decision; self.expectedInterface = expectedInterface
        self.observedInterface = observedInterface; self.observedGateway = observedGateway; self.matchesExpected = matchesExpected
    }
}
