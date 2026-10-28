import Foundation

public struct RouteTarget: Hashable, Codable, Sendable {
    public enum Destination: Hashable, Codable, Sendable {
        case viaGateway(String)
        case interface(String)
    }
    public let prefix: IPv4CIDR
    public let destination: Destination
    public init(_ prefix: IPv4CIDR, _ destination: Destination) {
        self.prefix = prefix
        self.destination = destination
    }
    /// Exact, prevalidated argv. Never use a shell to execute these.
    public func arguments(adding: Bool) -> [String] {
        let operation = adding ? "add" : "delete"
        switch destination {
        case .viaGateway(let gateway):
            return ["-n", operation, "-net", prefix.description, gateway]
        case .interface(let interface):
            return ["-n", operation, "-net", prefix.description, "-interface", interface]
        }
    }
}

public struct RoutePlan: Sendable {
    public let endpoint: RouteTarget
    public let direct: [RouteTarget]
    public let vpnDefaults: [RouteTarget]
    public var installOrder: [RouteTarget] { [endpoint] + direct + vpnDefaults }
    public var removalOrder: [RouteTarget] { installOrder.reversed() }
}

public enum RoutePlanningError: Error, Equatable, LocalizedError {
    case invalidGateway, invalidInterface, badServerAddress, blockedServerAddress, routeCollision
    public var errorDescription: String? {
        switch self {
        case .invalidGateway:
            return L10n.text("无法核验物理出口；请检查本地网络，并断开其它 VPN／TUN 后重试。")
        case .invalidInterface:
            return L10n.text("无法核验 VPN 隧道接口，路由未应用。")
        case .badServerAddress, .blockedServerAddress:
            return L10n.text("服务器端点不适用于受管路由；请检查配置中的服务器地址。")
        case .routeCollision:
            return L10n.text("系统已有冲突路由；请先断开其它 VPN／TUN，未覆盖已有路由。")
        }
    }
}

public enum RoutePlanner {
    /// Produces a *proposal*, not system changes. The helper must inspect existing routes,
    /// capture rollback state, then apply and validate this plan transactionally.
    public static func build(
        serverIPv4: String, physicalGateway: String, vpnInterface: String,
        localPrefixes: [IPv4CIDR], china: RuleSet?, custom: CustomRuleSet = .empty
    ) throws -> RoutePlan {
        guard let physical = IPv4CIDR.parseAddress(physicalGateway),
              physical != 0 else { throw RoutePlanningError.invalidGateway }
        guard vpnInterface.hasPrefix("utun"),
              vpnInterface.dropFirst(4).allSatisfy({ $0.isNumber }),
              vpnInterface.count > 4, vpnInterface.count <= 12
        else { throw RoutePlanningError.invalidInterface }
        guard let server = IPv4CIDR.parseAddress(serverIPv4) else {
            throw RoutePlanningError.badServerAddress
        }
        // Refuse tunnelling to loopback/multicast as a VPN server.
        if (server >> 24) == 0 || (server >> 24) == 127 || (server >> 24) >= 224 {
            throw RoutePlanningError.blockedServerAddress
        }
        let host = try IPv4CIDR("\(serverIPv4)/32")
        let endpoint = RouteTarget(host, .viaGateway(physicalGateway))
        // Retain the system's connected/local routes; do not create conflicting routes.
        let direct = try custom.directPrefixes(country: china, local: localPrefixes, endpoint: serverIPv4)
            .map { RouteTarget($0, .viaGateway(physicalGateway)) }
        let defaults: [RouteTarget] = [
            RouteTarget(try IPv4CIDR("0.0.0.0/1"), .interface(vpnInterface)),
            RouteTarget(try IPv4CIDR("128.0.0.0/1"), .interface(vpnInterface))
        ]
        return RoutePlan(endpoint: endpoint, direct: direct, vpnDefaults: defaults)
    }
}

/// A minimal auditable mutation journal. Records only mutations that actually succeeded.
/// "Existing route" must not be added to this journal.
public struct RouteJournal: Codable, Sendable {
    public let session: UUID
    public var applied: [String]
    public init(session: UUID) { self.session = session; self.applied = [] }
    public mutating func recorded(_ route: RouteTarget) { applied.append(route.prefix.description) }
}
