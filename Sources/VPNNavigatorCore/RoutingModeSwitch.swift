import Foundation

/// An exact revision, rather than saved profile metadata, identifies live routing.
public struct RoutingModeSwitchRequest: Equatable, Sendable {
    public let profileID: UUID
    public let attemptID: UUID
    public let revision: UUID
    public let previous: RoutingMode
    public let target: RoutingMode
    public init(report: SessionReport, target: RoutingMode) throws {
        guard report.state == .connected, report.challenge == nil,
              let profileID = report.activeProfileID, let attemptID = report.attemptID,
              let revision = report.routingRevision, let mode = report.routingMode,
              mode != .original, target != .original else { throw RoutingModeSwitchError.unavailable }
        self.profileID = profileID; self.attemptID = attemptID
        self.revision = revision; previous = mode; self.target = target
    }
    public func matches(_ report: SessionReport) -> Bool {
        report.state == .connected && report.challenge == nil && report.activeProfileID == profileID &&
        report.attemptID == attemptID && report.routingRevision == revision && report.routingMode == previous
    }
}

public struct ManagedRouteTransition: Sendable {
    public let mode: RoutingMode
    public let rules: RuleSet?
    public let plan: RoutePlan
    public let added: [RouteTarget]
    public let removed: [RouteTarget]
    public var tightensDirectAccess: Bool { !removed.isEmpty }
    public init(current: RoutePlan, target: RoutingMode, ruleText: String, local: [IPv4CIDR]) throws {
        guard ruleText.utf8.count <= 2_000_000 else { throw RuleError.tooLarge }
        guard target != .original, case .viaGateway(let gateway) = current.endpoint.destination,
              let first = current.vpnDefaults.first, case .interface(let tunnel) = first.destination else {
            throw RoutingModeSwitchError.unavailable
        }
        let country: RuleSet?
        if target == .chinaDirect {
            let parsed = try RuleSet(text: ruleText)
            guard parsed.routes.count >= 100 else { throw RoutingModeSwitchError.missingRules }
            country = parsed
        } else { country = nil }
        let next = try RoutePlanner.build(serverIPv4: IPv4CIDR.parseAddressString(current.endpoint.prefix.network),
            physicalGateway: gateway, vpnInterface: tunnel, localPrefixes: local, china: country)
        guard current.endpoint == next.endpoint, current.vpnDefaults == next.vpnDefaults else {
            throw RoutingModeSwitchError.unavailable
        }
        mode = target; rules = country; plan = next
        let old = Set(current.direct), new = Set(next.direct)
        added = new.subtracting(old).sorted { $0.prefix < $1.prefix }
        removed = old.subtracting(new).sorted { $0.prefix < $1.prefix }
    }
}
public enum RoutingModeSwitchError: Error, LocalizedError {
    case unavailable, stale, missingRules
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "当前会话不支持在线切换。原始配置模式需先断开连接。"
        case .stale: return "会话或路由版本已改变，请重新确认后切换。"
        case .missingRules: return "规则路由需要至少 100 条已校验的中国 IPv4 规则。"
        }
    }
}
