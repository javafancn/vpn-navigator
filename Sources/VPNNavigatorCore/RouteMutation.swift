import Foundation

/// A durable record describing a system-route operation whose outcome cannot
/// be inferred safely after an abrupt root-helper failure.
///
/// A pending operation does NOT prove that the app owns the route. An administrator
/// must inspect the route and the old OpenVPN process before clearing this marker.
public struct RouteMutation: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case add, remove }
    public let id: UUID
    public let action: Action
    public let route: RouteTarget

    public init(id: UUID = UUID(), action: Action, route: RouteTarget) {
        self.id = id
        self.action = action
        self.route = route
    }
}

/// Explicit recovery gate shared between UI/helper, independent of filesystem.
public enum RouteRecoveryGate {
    public static func canAutomaticallyRecover(
        hasPendingMutation: Bool, hasOrphanedOpenVPN: Bool
    ) -> Bool {
        !hasPendingMutation && !hasOrphanedOpenVPN
    }
}
