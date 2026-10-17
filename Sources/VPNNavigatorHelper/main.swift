import Foundation
import Darwin
import VPNNavigatorCore

// Internal DNS-hook operation: fixed journal, typed tunnel, root only. It
// cannot launch OpenVPN, accept a path or run an arbitrary command.
if CommandLine.arguments.dropFirst().first == "--commit-dns" {
    guard getuid() == 0, CommandLine.arguments.count == 3,
          DNSRecoveryPolicy.validTunnel(CommandLine.arguments[2]) else { exit(1) }
    do { try DNSRecoveryJournal().commit(tunnel: CommandLine.arguments[2]); exit(0) }
    catch { exit(1) }
}
#if DEBUG
if CommandLine.arguments.dropFirst().first == "--self-test-dns-journal" {
    do { try DNSJournalSelfTest.run(); print("DNS journal ownership and conflict checks passed."); exit(0) }
    catch { fputs("DNS journal self-test failed.\n", stderr); exit(1) }
}
#endif

final class HelperService: NSObject, VPNNavigatorHelperAPI {
    private let engine = ManagedTunnel()
    // All tunnel actions and state transitions use one serial queue.
    private var queue: DispatchQueue { engine.queue }
    private var networkMonitor: NetworkChangeMonitor?
    private var terminationSignal: DispatchSourceSignal?
    override init() {
        super.init()
        networkMonitor = NetworkChangeMonitor { [weak self] in
            self?.queue.async { [weak self] in self?.engine.verifyPhysicalNetwork() }
        }
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termination.setEventHandler { [weak self] in
            self?.engine.stop()
            exit(0)
        }
        terminationSignal = termination; termination.resume()
    }

    func health(reply: @escaping (String) -> Void) {
        reply("VPN Navigator Helper (signed)")
    }
    func connect(profile: String, profileID: String, mode: String, rules: String,
                 username: String, password: String, preferences: String,
                 reply: @escaping (String) -> Void) {
        queue.async {
            guard let profileUUID = UUID(uuidString: profileID) else {
                reply("ERROR: Invalid profile identifier"); return
            }
            guard let requested = RoutingMode(rawValue: mode) else {
                reply("ERROR: Invalid route mode"); return
            }
            do {
                try self.engine.start(profile: profile, profileID: profileUUID,
                                      mode: requested, ruleText: rules,
                                      username: username, password: password,
                                      preferences: try SessionPreferences.decoded(preferences))
                reply("Connecting. Await tunnel state and route validation.")
            } catch { reply("ERROR: \(error.localizedDescription)") }
        }
    }
    func submitChallenge(id: String, response: String, reply: @escaping (String) -> Void) {
        queue.async {
            do { try self.engine.submitChallenge(id: id, response: response); reply("Accepted") }
            catch { reply("ERROR: 认证请求已失效或响应无效，请重试连接。") }
        }
    }
    func diagnosticEvents(reply: @escaping (String) -> Void) {
        queue.async {
            let data = (try? JSONEncoder().encode(self.engine.diagnosticEvents)) ?? Data()
            reply(String(decoding: data, as: UTF8.self))
        }
    }
    func disconnect(reply: @escaping (String) -> Void) {
        queue.async {
            self.engine.stop()
            if self.engine.state == .disconnected {
                reply("Disconnected")
            } else {
                reply("ERROR: " + self.engine.message)
            }
        }
    }
    func connectionStatus(reply: @escaping (String) -> Void) {
        queue.async { reply("\(self.engine.state.rawValue): \(self.engine.message)") }
    }
    func activeProfile(reply: @escaping (String) -> Void) {
        queue.async { reply(self.engine.activeProfileID?.uuidString ?? "") }
    }
    func sessionSnapshot(reply: @escaping (String) -> Void) {
        queue.async {
            let report = SessionReport(
                state: self.engine.state,
                message: self.engine.message,
                activeProfileID: self.engine.activeProfileID,
                receivedBytes: self.engine.traffic?.receivedBytes,
                sentBytes: self.engine.traffic?.sentBytes, challenge: self.engine.challenge)
            guard let bytes = try? JSONEncoder().encode(report),
                  let output = String(data: bytes, encoding: .utf8) else {
                reply("ERROR: Cannot serialize tunnel status")
                return
            }
            reply(output)
        }
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

