import Foundation
import VPNNavigatorCore

@MainActor
struct RoutingModeService {
    var snapshot: () async -> SessionReport?
    var apply: (RoutingModeSwitchRequest, String) async -> String
    static var live: Self {
        Self(snapshot: { await HelperClient.shared.sessionReport() },
             apply: { await HelperClient.shared.switchRoutingMode($0, rules: $1) })
    }
}
