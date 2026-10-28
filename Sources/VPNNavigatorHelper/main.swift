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
if CommandLine.arguments.dropFirst().first == "--self-test-route-pressure-legacy" {
    do { try RouteCommandPressureSelfTest.run(legacy: true); exit(0) }
    catch { fputs("Legacy resource observation stopped: \(error.localizedDescription)\n", stderr); exit(2) }
}
if CommandLine.arguments.dropFirst().first == "--self-test-management" {
    guard getuid() != 0, CommandLine.arguments.count == 4 else { exit(1) }
    do {
        try ManagementSocketSelfTest.run(path: CommandLine.arguments[2], scenario: CommandLine.arguments[3])
        print("Management socket fixture passed."); exit(0)
    } catch { fputs("Management socket self-test failed.\n", stderr); exit(1) }
}
if CommandLine.arguments.dropFirst().first == "--self-test-route-ordering" {
    do { try RouteExecutionSelfTest.run(); print("Route rollback ordering and cancellation checks passed."); exit(0) }
    catch { fputs("Route ordering self-test failed.\n", stderr); exit(1) }
}
if CommandLine.arguments.dropFirst().first == "--self-test-pf-install" {
    guard getuid() == 0, CommandLine.arguments.count == 3,
          let port = UInt16(CommandLine.arguments[2]), port > 1024 else { exit(1) }
    let rules = "block drop out quick on lo0 inet proto tcp from any to 127.0.0.1 port \(port)\n"
    do { try PacketFilterGuard().activate(rules, resetExistingStates: false); exit(0) }
    catch { fputs("PF loopback guard installation failed.\n", stderr); exit(1) }
}
if CommandLine.arguments.dropFirst().first == "--self-test-pf-release" {
    guard getuid() == 0 else { exit(1) }
    do { try PacketFilterGuard().release(); exit(0) } catch { exit(1) }
}
if CommandLine.arguments.dropFirst().first == "--self-test-dns-journal" {
    do { try DNSJournalSelfTest.run(); print("DNS journal ownership and conflict checks passed."); exit(0) }
    catch { fputs("DNS journal self-test failed.\n", stderr); exit(1) }
}
#endif

#if VPNNAV_LOCAL_TEST
if CommandLine.arguments.dropFirst().first == "--self-test-route-pressure" {
    guard getuid() == 0, CommandLine.arguments.count == 2, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
          let approval = try? LocalInstallation.load(), LocalInstallation.selfMatches([.helper], approval: approval) else { exit(1) }
    do { try RouteCommandPressureSelfTest.run(); exit(0) }
    catch { fputs("Route resource pressure fixture failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.dropFirst().first == "--self-test-ipv6-kernel" {
    guard getuid() == 0, CommandLine.arguments.count == 3, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
          let approval = try? LocalInstallation.load(), LocalInstallation.selfMatches([.helper], approval: approval) else { exit(1) }
    do { try IPv6KernelSelfTest.run(tunnel: CommandLine.arguments[2]); exit(0) }
    catch { fputs("IPv6 kernel fixture failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
#endif

if BuildChannel.isLocal {
    guard let approval = try? LocalInstallation.load(), LocalInstallation.selfMatches([.helper], approval: approval) else { exit(1) }
}

final class HelperService: NSObject, VPNNavigatorHelperAPI {
    private let engine = ManagedTunnel()
    private var retiring = false
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

    func stopWhenIdle(reply: @escaping (String) -> Void) {
        queue.async {
            guard !self.retiring,
                  HelperQuitPolicy.mayStop(self.currentSessionReport(),
                    hasRecoveryEvidence: LocalInstallation.hasRecoveryEvidence,
                    installationPending: BuildChannel.isLocal && LocalInstallation.isInstallationPending) else {
                reply("ERROR: Helper still owns a session or network recovery; exit refused")
                return
            }
            self.retiring = true
            reply(HelperQuitReceipt(processID: getpid()).json)
            // Let XPC deliver the receipt. No launchctl bootout, approval
            // removal or KeepAlive: the next authenticated demand can wake us.
            self.queue.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }
    func prepareLocalMaintenance(reply: @escaping (String) -> Void) {
        guard BuildChannel.isLocal else { reply("ERROR: Local maintenance is unavailable in this channel"); return }
        engine.cancellation.cancel(nil)
        queue.async {
            guard BuildChannel.isLocal, self.engine.state == .disconnected, !self.engine.networkRecoveryRequired else {
                reply("ERROR: 请先断开并完成网络恢复。"); return
            }
            do {
                try LocalInstallation.removeApproval()
                self.retiring = true
                reply("Local services disabled")
                self.queue.asyncAfter(deadline: .now() + 0.2) {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    task.arguments = ["bootout", "system/" + LocalInstallation.daemonLabel]
                    try? task.run()
                }
            } catch { reply("ERROR: " + error.localizedDescription) }
        }
    }
    func health(reply: @escaping (String) -> Void) {
        reply(BuildChannel.isLocal ? "VPN Navigator Helper (local)" : "VPN Navigator Helper (signed)")
    }
    func connect(profile: String, profileID: String, mode: String, rules: String,
                 username: String, password: String, preferences: String, attemptID: String,
                 reply: @escaping (String) -> Void) {
        let generation = engine.cancellation.snapshot()
        queue.async {
            guard !self.retiring else { reply("ERROR: Local services are retiring"); return }
            guard !BuildChannel.isLocal || !LocalInstallation.isInstallationPending else {
                reply("ERROR: " + LocalInstallError.incomplete.localizedDescription); return
            }
            guard let requestID = UUID(uuidString: attemptID) else { reply("ERROR: Invalid connection attempt"); return }
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
                                      preferences: try SessionPreferences.decoded(preferences), attemptID: requestID, cancellationGeneration: generation)
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
    func disconnect(cancelAttemptID: String, reply: @escaping (String) -> Void) {
        engine.cancellation.cancel(UUID(uuidString: cancelAttemptID))
        queue.async {
            self.engine.stop(releaseProtection: true)
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
    func disconnectSession(expectedProfileID: String, expectedAttemptID: String, reply: @escaping (String) -> Void) {
        queue.async {
            guard let profileID = UUID(uuidString: expectedProfileID),
                  let attemptID = UUID(uuidString: expectedAttemptID),
                  QuickAccessSession(profileID: profileID, attemptID: attemptID).matches(self.currentSessionReport()) else {
                reply("ERROR: Connection changed; switch confirmation expired"); return
            }
            // Identity check and stop execute on the same engine queue. A
            // stale request cannot cancel a newer attempt or its generation.
            self.engine.cancellation.cancel(attemptID)
            self.engine.stop(releaseProtection: true)
            reply(self.engine.state == .disconnected ? "Disconnected" : "ERROR: " + self.engine.message)
        }
    }
    private func currentSessionReport() -> SessionReport {
        SessionReport(state: engine.state, message: engine.message, activeProfileID: engine.activeProfileID,
            receivedBytes: engine.traffic?.receivedBytes, sentBytes: engine.traffic?.sentBytes,
            challenge: engine.challenge, firewallActive: engine.firewallActive,
            firewallRecoveryRequired: engine.firewallRecoveryRequired, attemptID: engine.activeAttemptID,
            networkRecoveryRequired: engine.networkRecoveryRequired,
            routingMode: engine.routingMode, routingRevision: engine.routingRevision,
            customRuleDigest: engine.customRuleDigest, customRuleCount: engine.customRuleCount, ipStack: engine.ipStack, failureCode: engine.state == .failed ? engine.failureCode : nil)
    }
    func activeProfile(reply: @escaping (String) -> Void) {
        queue.async { reply(self.engine.activeProfileID?.uuidString ?? "") }
    }
    func sessionSnapshot(reply: @escaping (String) -> Void) {
        queue.async {
            let report = self.currentSessionReport()
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
    func explainRoute(_ text: String, reply: @escaping (String) -> Void) {
        queue.async {
            guard !self.retiring, !BuildChannel.isLocal || !LocalInstallation.isInstallationPending else { reply("ERROR: Service unavailable"); return }
            do {
                let request = try RouteLookupRequest.decoded(text)
                guard request.matches(self.currentSessionReport()) else { throw RoutingModeSwitchError.stale }
                let result = try self.engine.explainRoute(request)
                reply(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
            } catch { reply("ERROR: " + error.localizedDescription) }
        }
    }
    func switchRoutingMode(mode: String, rules: String, expectedProfileID: String, expectedAttemptID: String,
                           expectedMode: String, expectedRevision: String, reply: @escaping (String) -> Void) {
        queue.async {
            guard !self.retiring, !BuildChannel.isLocal || !LocalInstallation.isInstallationPending else {
                reply("ERROR: " + LocalInstallError.incomplete.localizedDescription); return
            }
            do {
                guard let target = RoutingMode(rawValue: mode) else { throw RoutingModeSwitchError.unavailable }
                let request = try RoutingModeSwitchRequest(report: self.currentSessionReport(), target: target)
                guard UUID(uuidString: expectedProfileID) == request.profileID,
                      UUID(uuidString: expectedAttemptID) == request.attemptID,
                      UUID(uuidString: expectedRevision) == request.revision,
                      RoutingMode(rawValue: expectedMode) == request.previous else { throw RoutingModeSwitchError.stale }
                // Check and mutate on the same serial queue; stale requests
                // cannot affect a later connection or a newer route revision.
                try self.engine.switchRoutingMode(to: target, ruleText: rules)
                reply("Routing mode applied")
            } catch { reply("ERROR: " + error.localizedDescription) }
        }
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = PeerVerifier.clientRequirement(uid: connection.effectiveUserIdentifier) else { return false }
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

