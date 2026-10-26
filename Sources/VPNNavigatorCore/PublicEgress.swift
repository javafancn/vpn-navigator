import Foundation

public enum EgressFamily: String, CaseIterable, Identifiable, Sendable {
    case ipv4, ipv6
    public var id: String { rawValue }
    public var title: String { self == .ipv4 ? "IPv4" : "IPv6" }
    public var endpoint: URL { URL(string: self == .ipv4 ? "https://api.ipify.org/" : "https://api6.ipify.org/")! }
    public func matches(_ address: String) -> Bool { self == .ipv4 ? IPv4CIDR.parseAddress(address) != nil : IPAddress.isIPv6(address) }
}
public enum EgressProbeFailure: Error, Equatable, Sendable, LocalizedError {
    case timeout, transport, httpStatus, redirect, tooLarge, invalidResponse, wrongFamily, nonPublicAddress, authentication
    public var errorDescription: String? {
        switch self {
        case .timeout: return L10n.text("检测服务未在期限内响应，请检查网络或稍后重试。")
        case .transport: return L10n.text("未能连接检测服务；可能与地址族可用性、阻断或服务状态有关。")
        case .httpStatus: return L10n.text("检测服务未返回成功状态，本次未取得出口地址。")
        case .redirect: return L10n.text("检测服务要求跳转；为固定请求范围，本次未跟随跳转。")
        case .tooLarge: return L10n.text("检测响应超过地址数据上限，已停止读取。")
        case .invalidResponse: return L10n.text("检测服务未返回有效的单个 IP 地址。")
        case .wrongFamily: return L10n.text("检测响应的地址族与所选检测不符。")
        case .nonPublicAddress: return L10n.text("检测响应不是支持核验的公网地址。")
        case .authentication: return L10n.text("检测服务要求额外身份验证，本次未提供凭据。")
        }
    }
}
public enum PublicEgressAddress {
    public static let maximumBytes = 128
    public static func parse(_ data: Data, family: EgressFamily) throws -> String {
        guard data.count <= maximumBytes else { throw EgressProbeFailure.tooLarge }
        guard !data.isEmpty, data.allSatisfy({ $0 < 128 }), let text = String(data: data, encoding: .utf8),
              let canonical = IPAddress.canonical(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw EgressProbeFailure.invalidResponse }
        guard family.matches(canonical) else { throw EgressProbeFailure.wrongFamily }
        guard isPublic(canonical) else { throw EgressProbeFailure.nonPublicAddress }
        return canonical
    }
    public static func isPublic(_ address: String) -> Bool {
        if IPv4CIDR.parseAddress(address) != nil { return (try? RuleSet(text: address + "/32")) != nil }
        // Conservative global-unicast scope, excluding special-purpose and
        // documentation ranges supported by the rule parser and RFC 9637.
        guard (try? IPv6RuleSet(text: address + "/128")) != nil,
              (try? IPv6CIDR("3fff::/20").contains(address)) != true else { return false }
        return true
    }
}
public struct EgressHTTPResult: Equatable, Sendable {
    public let address: String
    public let remoteAddress: String?
    public let usedProxy: Bool?
    public let cacheHit: Bool?
    public let milliseconds: Double
    public init(address: String, remoteAddress: String?, usedProxy: Bool?, cacheHit: Bool?, milliseconds: Double) {
        self.address = address; self.remoteAddress = remoteAddress; self.usedProxy = usedProxy; self.cacheHit = cacheHit; self.milliseconds = milliseconds
    }
}
public struct EgressSessionContext: Equatable, Sendable {
    public let state: TunnelState?
    public let profileID: UUID?
    public let attemptID: UUID?
    public let mode: RoutingMode?
    public let revision: UUID?
    public let stack: TunnelIPStack?
    public let needsRecovery: Bool
    public let firewallActive: Bool
    public let hasChallenge: Bool
    public init(_ report: SessionReport?) {
        state = report?.state; profileID = report?.activeProfileID; attemptID = report?.attemptID
        mode = report?.routingMode; revision = report?.routingRevision; stack = report?.ipStack
        needsRecovery = report?.requiresNetworkRecovery ?? false; firewallActive = report?.firewallActive ?? false; hasChallenge = report?.challenge != nil
    }
    public var verifiedConnection: Bool {
        state == .connected && profileID != nil && attemptID != nil && mode != nil && !hasChallenge && !needsRecovery && (mode == .original || revision != nil)
    }
    public var verifiedDisconnection: Bool { state == .disconnected && profileID == nil && !needsRecovery && !hasChallenge }
    public func matches(_ request: RouteLookupRequest) -> Bool {
        verifiedConnection && profileID == request.profileID && attemptID == request.attemptID && mode == request.mode && revision == request.revision
    }
}
public enum EgressPathAssessment: String, Equatable, Sendable {
    case vpnRoute, directRoute, systemRoute, mismatch, unknown, stale, standalone
    public var title: String {
        switch self {
        case .vpnRoute: return L10n.text("检测目标路由匹配 VPN")
        case .directRoute: return L10n.text("检测目标按当前规则直连")
        case .systemRoute: return L10n.text("原始配置：仅展示系统观测")
        case .mismatch: return L10n.text("检测目标与当前策略不一致")
        case .unknown: return L10n.text("已取得地址，路径尚无法核验")
        case .stale: return L10n.text("会话已改变，结果已过期")
        case .standalone: return L10n.text("未连接 VPN，仅显示请求出口")
        }
    }
    public static func evaluate(family: EgressFamily, response: EgressHTTPResult, before: EgressSessionContext,
                                after: EgressSessionContext, route: RouteLookupResult?) -> Self {
        guard before == after else { return .stale }
        guard family.matches(response.address), PublicEgressAddress.isPublic(response.address) else { return .unknown }
        guard before.verifiedConnection else { return before.verifiedDisconnection ? .standalone : .unknown }
        guard response.usedProxy == false, response.cacheHit == false, let remote = response.remoteAddress,
              family.matches(remote), PublicEgressAddress.isPublic(remote), let route,
              IPAddress.canonical(remote) == route.request.ip, before.matches(route.request), route.decision.ip == route.request.ip else { return .unknown }
        if route.request.mode == .original { return .systemRoute }
        if route.decision.path == .blocked { return .mismatch }
        guard let expected = route.expectedInterface, safeInterface(expected), safeInterface(route.observedInterface),
              route.matchesExpected != nil else { return .unknown }
        guard route.matchesExpected == true, expected == route.observedInterface else { return .mismatch }
        switch route.decision.path {
        case .vpn: return DNSRecoveryPolicy.validTunnel(expected) ? .vpnRoute : .unknown
        case .direct: return LeakGuardPolicy.validPhysical(expected) ? .directRoute : .unknown
        default: return .unknown
        }
    }
    public static func safeInterface(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
