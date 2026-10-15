import Foundation
import VPNNavigatorCore

final class HelperService: NSObject, VPNNavigatorHelperAPI {
    private let engine = ManagedTunnel()
    // All tunnel actions and state transitions use one serial queue.
    private var queue: DispatchQueue { engine.queue }

    func health(reply: @escaping (String) -> Void) {
        reply("VPN Navigator Helper (signed)")
    }
    func connect(profile: String, mode: String, rules: String,
                 username: String, password: String,
                 reply: @escaping (String) -> Void) {
        queue.async {
            guard let requested = RoutingMode(rawValue: mode) else {
                reply("ERROR: Invalid route mode"); return
            }
            do {
                try self.engine.start(profile: profile, mode: requested, ruleText: rules,
                                      username: username, password: password)
                reply("Connecting. Await tunnel state and route validation.")
            } catch { reply("ERROR: \(error.localizedDescription)") }
        }
    }
    func disconnect(reply: @escaping (String) -> Void) {
        queue.async { self.engine.stop(); reply("Disconnected") }
    }
    func connectionStatus(reply: @escaping (String) -> Void) {
        queue.async { reply("\(self.engine.state.rawValue): \(self.engine.message)") }
    }
    func trafficStatus(reply: @escaping (String) -> Void) {
        queue.async {
            guard let value = self.engine.traffic else { reply(""); return }
            reply("\(value.receivedBytes),\(value.sentBytes)")
        }
    }
    func recoverOrphanedRoutes(reply: @escaping (String) -> Void) {
        queue.async { reply(self.engine.retryRouteRecovery()) }
    }
    func updateRules(_ text: String, reply: @escaping (String) -> Void) {
        queue.async {
            if self.engine.state == .connecting || self.engine.state == .authenticating ||
               self.engine.state == .reconnecting || self.engine.state == .stopping {
                reply("ERROR: VPN session is changing state; retry rule update")
                return
            }
            if !self.engine.activeSplitRoutes {
                reply("NO_ACTIVE_SPLIT")
                return
            }
            do { try self.engine.changeRules(text); reply("Rules applied") }
            catch { reply("ERROR: \(error.localizedDescription)") }
        }
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = PeerVerifier.clientRequirement() else { return false }
        // macOS enforces this requirement against every incoming XPC message.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: VPNNavigatorHelperAPI.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: HelperIdentity.machService)
let delegate = HelperDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
