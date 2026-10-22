import Foundation

/// The helper revalidates preferences received over XPC. These settings never
/// authorize a managed reconnect without a validated traffic guard.
public struct SessionPreferences: Codable, Equatable, Sendable {
    public var customRules: [CustomRouteRule]?
    public var connectionTimeout: Int
    public var reconnectManaged: Bool
    public var killSwitch: Bool
    public var reconnectOriginal: Bool
    public init(connectionTimeout: Int = 60, reconnectOriginal: Bool = true, killSwitch: Bool = false, reconnectManaged: Bool = false, customRules: [CustomRouteRule] = []) {
        self.customRules = customRules.isEmpty ? nil : customRules
        self.connectionTimeout = min(180, max(20, connectionTimeout))
        self.reconnectOriginal = reconnectOriginal
        self.killSwitch = killSwitch
        self.reconnectManaged = reconnectManaged && killSwitch
    }
    public static func decoded(_ text: String) throws -> Self {
        guard text.utf8.count <= 64_000, let data = text.data(using: .utf8) else {
            throw SessionPreferenceError.invalid
        }
        let input = try JSONDecoder().decode(Self.self, from: data)
        guard (20...180).contains(input.connectionTimeout), !input.reconnectManaged || input.killSwitch else {
            throw SessionPreferenceError.invalid
        }
        _ = try CustomRuleSet(input.customRules ?? [])
        return input
    }
    public var json: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }
}
public enum SessionPreferenceError: Error { case invalid }

public enum ConnectionControl {
    public static func canStop(_ state: TunnelState) -> Bool {
        [.connecting, .authenticating, .connected, .reconnecting, .failed].contains(state)
    }
    public static func inProgress(_ state: TunnelState) -> Bool {
        [.connecting, .authenticating, .reconnecting, .stopping].contains(state)
    }
}
