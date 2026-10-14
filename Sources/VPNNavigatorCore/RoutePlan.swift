import Foundation

public struct RouteTarget: Hashable, Sendable {
    public enum Destination: Hashable, Sendable {
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

public enum RoutePlanningError: Error, Equatable {
    case invalidGateway, invalidInterface, badServerAddress, blockedServerAddress, routeCollision
}

public enum RoutePlanner {
    /// Produces a *proposal*, not system changes. The helper must inspect existing routes,
    /// capture rollback state, then apply and validate this plan transactionally.
    public static func build(
        serverIPv4: String, physicalGateway: String, vpnInterface: String,
        localPrefixes: [IPv4CIDR], china: RuleSet
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
        let localSet = Set(localPrefixes)
        let direct = china.routes.filter { !localSet.contains($0) && $0 != host }
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
