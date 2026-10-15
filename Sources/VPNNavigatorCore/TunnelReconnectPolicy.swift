import Foundation

/// A route-managed tunnel cannot safely keep its old route policy through an
/// OpenVPN RECONNECTING event without a proven firewall guard. Until that
/// exists, terminate the session and require an explicit new connection.
public enum TunnelReconnectPolicy {
    public enum Action: Equatable {
        case permitOpenVPNReconnect
        case stopAndRestoreOnlyAfterExit
    }

    public static func action(for mode: RoutingMode) -> Action {
        switch mode {
        case .original: return .permitOpenVPNReconnect
        case .fullVPN, .chinaDirect: return .stopAndRestoreOnlyAfterExit
        }
    }
}
