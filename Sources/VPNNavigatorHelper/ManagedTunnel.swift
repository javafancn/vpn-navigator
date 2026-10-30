import Foundation
import Darwin
import VPNNavigatorCore

/// Root-owned, single-session OpenVPN process. The caller has already passed code-signing verification.
final class ManagedTunnel {
    let queue = DispatchQueue(label: "VPNNavigator.ManagedTunnel")
    let cancellation = SessionCancellation()
    private(set) var activeAttemptID: UUID?
    private var cancellationGeneration: UInt64 = 0
    private var cancellationRequested: Bool {
        activeAttemptID.map { cancellation.isCancelled($0, generation: cancellationGeneration) } ?? false
    }
    private struct ReconnectContext {
        let profile: String
        let profileID: UUID
        let attemptID: UUID
        let mode: RoutingMode
        let username: String
        let password: String
    }
    private var reconnectContext: ReconnectContext?
    private var retryBudget = ReconnectBudget()
    private var retryWork: DispatchWorkItem?
    private var attemptExpiresAt: UInt64?
    private var attemptExpired: Bool { attemptExpiresAt.map { DispatchTime.now().uptimeNanoseconds >= $0 } ?? false }
    private var attemptTimer: DispatchSourceTimer?
    private var preferences = SessionPreferences()
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private let eventStore = DiagnosticEventStore(file: URL(fileURLWithPath: "/var/run/vpn-navigator/events.json"))
    var diagnosticEvents: [DiagnosticEvent] { eventStore.events() }
    private var networkWatchdog: DispatchSourceTimer?
    private let workdir = URL(fileURLWithPath: "/var/run/vpn-navigator", isDirectory: true)
    private var process: Process?
    private var management: ManagementSocket?
    private(set) var challenge: AuthenticationChallenge?
    private var routing: RouteExecutor?
    private let dnsRecovery = DNSRecoveryJournal()
    private var splitDNS: SplitDNSProxy?
    private var domesticDNSServers: [String] = []
    private var managedDNSServers: [String] = []
    private let packetGuard = PacketFilterGuard()
    private var guardPolicy: LeakGuardPolicy?
    private var releaseProtectionOnExit = false
    private var protectionTeardownBlocked = false
    var firewallActive: Bool { packetGuard.active }
    private var hasLiveSessionOwner: Bool {
        SessionRecoveryPolicy.hasLiveOwner(state: state, profileID: activeProfileID,
            attemptID: activeAttemptID, ownedChildRunning: process?.isRunning == true)
    }
    var firewallRecoveryRequired: Bool {
        packetGuard.requiresRecovery && (!packetGuard.active || !hasLiveSessionOwner || protectionTeardownBlocked)
    }
    var networkRecoveryRequired: Bool {
        firewallRecoveryRequired || (!hasLiveSessionOwner && (dnsRecovery.exists || hasPersistentSessionEvidence ||
            FileManager.default.fileExists(atPath: workdir.appendingPathComponent("routes.journal").path)))
    }
    private var activeMode: RoutingMode = .original
    private(set) var routingRevision: UUID?
    var routingMode: RoutingMode? { activeProfileID == nil ? nil : activeMode }
    private(set) var activeProfileID: UUID?
    private var custom = CustomRuleSet.empty
    var customRuleDigest: String? { activeProfileID == nil ? nil : custom.digest }
    var customRuleCount: Int? { activeProfileID == nil ? nil : custom.active.count }
    private var rules: RuleSet?
    private var activePlan: DualStackRoutePlan?
    private var rules6: IPv6RuleSet?
    private(set) var ipStack: TunnelIPStack?
    private var protectedLocalNetworks: [IPv4CIDR] = []
    private var protectedPhysicalInterface: String?
    private var protectedVPNInterface: String?
    private(set) var failureCode: DiagnosticCode?
    private var lastError: String?
    private var orphanRecordFile: URL { workdir.appendingPathComponent("openvpn-child.json") }
    private var hasPersistentSessionEvidence: Bool {
        FileManager.default.fileExists(atPath: workdir.appendingPathComponent("active.ovpn").path) ||
        FileManager.default.fileExists(atPath: orphanRecordFile.path)
    }

    init() {
        // Never remove routes while an OpenVPN process may still be alive
        // after an unexpected root-helper crash.
        let orphan = workdir.appendingPathComponent("active.ovpn")
        if FileManager.default.fileExists(atPath: orphan.path) ||
           FileManager.default.fileExists(atPath: orphanRecordFile.path) {
            state = .failed
            message = "Unverified previous OpenVPN session; do not automatically reclaim routes."
            return
        }
        if packetGuard.requiresRecovery {
            state = .failed; message = "断线保护有未完成的恢复记录，请执行安全网络恢复。"
            return
        }
        if dnsRecovery.exists {
            state = .failed
            message = "上次 DNS 事务尚未恢复，请执行安全网络恢复。"
            return
        }
        let leftover = workdir.appendingPathComponent("routes.journal")
        if FileManager.default.fileExists(atPath: leftover.path) {
            _ = RouteExecutor(journal: leftover)
            if FileManager.default.fileExists(atPath: leftover.path) {
                state = .failed
                message = "Unresolved or ambiguous route transaction requires manual verification."
            }
        }
    }
    private(set) var state: TunnelState = .disconnected
    private(set) var message = "Disconnected"
    private(set) var traffic: TunnelTraffic?
    var activeSplitRoutes: Bool { activeMode == .chinaDirect && routing != nil }

    func start(profile text: String, profileID: UUID, mode: RoutingMode, ruleText: String,
               username: String, password: String, preferences: SessionPreferences = .init(), reusingGuard: Bool = false, attemptID: UUID = UUID(), cancellationGeneration: UInt64? = nil) throws {
        let expiresAt = DispatchTime.now().uptimeNanoseconds + UInt64(preferences.connectionTimeout) * 1_000_000_000
        let capturedGeneration = cancellationGeneration ?? cancellation.snapshot()
        guard !cancellation.isCancelled(attemptID, generation: capturedGeneration) else { throw CancellationError() }
        guard getuid() == 0 else { throw TunnelError.needRoot }
        guard !FileManager.default.fileExists(atPath: workdir.appendingPathComponent("active.ovpn").path),
              !FileManager.default.fileExists(atPath: orphanRecordFile.path) else {
            throw TunnelError.orphanedSession
        }
        guard !FileManager.default.fileExists(atPath: workdir.appendingPathComponent("routes.journal").path) else {
            throw TunnelError.unresolvedRoutes
        }
        if reusingGuard {
            guard packetGuard.active, preferences.killSwitch, preferences.reconnectManaged else { throw LeakGuardError.unresolved }
            try packetGuard.verify()
        } else {
            guard !packetGuard.requiresRecovery else { throw LeakGuardError.unresolved }
            retryBudget = ReconnectBudget()
            reconnectContext = nil
        }
        releaseProtectionOnExit = false
        protectionTeardownBlocked = false
        guard !dnsRecovery.exists else { throw DNSJournalError.conflict }
        guard process == nil else { throw TunnelError.alreadyRunning }
        routingRevision = nil
        self.activeAttemptID = attemptID
        self.cancellationGeneration = capturedGeneration
        self.preferences = preferences
        custom = mode == .original ? .empty : try CustomRuleSet(preferences.customRules ?? [])
        attemptExpiresAt = expiresAt
        var validated = try ProfileSafety.validate(text)
        try ManagedRoutingPolicy.validate(validated, mode: mode)
        if mode != .original {
            // Read-only route lookup: sends no packets and runs before root
            // markers, DNS/PF changes or authentication. A successful lookup
            // is only a conflict screen; later route verification still runs.
            if let route = try? RouteExecutor.command("/sbin/route", ["-n", "get", "1.1.1.1"]),
               let interface = Self.parseValue("interface:", in: route), DNSRecoveryPolicy.validTunnel(interface) {
                throw RoutePlanningError.competingTunnel
            }
        }
        // Negotiate tunnel families before evaluating unsupported-family fallback.
        // Address-family fallback is checked after the server has assigned its tunnel addresses.
        if mode != .chinaDirect { rules = nil; rules6 = nil }
        if mode == .chinaDirect {
            let bundle = try RoutingRuleBundle.decoded(ruleText)
            rules = try RuleSet(text: bundle.ipv4)
            rules6 = try bundle.ipv6.map { try IPv6RuleSet(text: $0) }
            if let rules6, rules6.routes.count < 100 { throw DualStackError.missingRules }
            guard let rules, rules.routes.count >= 100 else { throw TunnelError.missingRules }
        }
        guard ManagementCredentialPolicy.allows(
            username: username, password: password,
            credentialsRequired: validated.requestsCredentials) else { throw TunnelError.badCredential }
        // Resolve and verify both required signed components before creating
        // any root-owned session markers or credentials.
        let binary = try ExecutableTrust.trustedOpenVPN().path
        let dnsHook = try ExecutableTrust.trustedDNSUpDown()
        let dnsLaunch = try OpenVPNCommand.dnsUpDownInvocation(dnsHook.path)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workdir.path)
        let configFile = workdir.appendingPathComponent("active.ovpn")
        // Early file/permission failures happen before Process.run(). They
        // must not leave a false orphan marker that permanently blocks startup.
        defer {
            if process == nil &&
               !FileManager.default.fileExists(
                   atPath: workdir.appendingPathComponent("routes.journal").path) {
                try? FileManager.default.removeItem(at: configFile)
                try? dnsRecovery.restore()
            }
        }
        if mode != .original && preferences.killSwitch {
            let endpoint = try GuardEndpoint.parse(validated.text)
            let numeric: String
            if let literal = IPAddress.canonical(endpoint.host) { numeric = literal }
            else {
                let answer = try RouteExecutor.command("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", endpoint.host])
                let v4 = Self.parseValue("ip_address:", in: answer).flatMap(IPAddress.canonical)
                let v6 = Self.parseValue("ipv6_address:", in: answer).flatMap(IPAddress.canonical)
                guard let value = endpoint.preferredFamily == 6 ? v6 : endpoint.preferredFamily == 4 ? v4 : (v4 ?? v6) else { throw LeakGuardError.invalid }
                numeric = value
            }
            let paths = try physicalPaths(endpoint: numeric)
            guard let physical = IPAddress.isIPv6(numeric) ? paths.1 : paths.0 else { throw TunnelError.noPhysicalGateway }
            let local = try localNetworks(paths: paths)
            let policy = try LeakGuardPolicy(physical: physical.interface, endpoint: numeric, port: endpoint.port,
                transport: endpoint.transport, local: local.0, country: [],
                managedDirect: try custom.directPrefixes(country: mode == .chinaDirect ? rules : nil, local: local.0, endpoint: numeric),
                physical4: paths.0?.interface, physical6: paths.1?.interface, local6: local.1)
            validated = try ProfileSafety.validate(endpoint.pinnedProfile(validated.text, address: numeric))
            try ensureAttempt()
            if reusingGuard { try packetGuard.replaceRules(policy.rules(tunnel: nil), resetExistingStates: true) }
            else { try packetGuard.activate(policy.rules(tunnel: nil)) }
            guardPolicy = policy
            reconnectContext = ReconnectContext(profile: validated.text, profileID: profileID, attemptID: attemptID, mode: mode, username: username, password: password)
        }
        try validated.text.write(to: configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        var options = ["--config", configFile.path]
        options += ManagedRoutingPolicy.openVPNArguments(mode: mode)
        if validated.requestsCredentials { options += ManagementAuthentication.openVPNArguments }
        let managementPath = workdir.appendingPathComponent("management.sock").path
        try? FileManager.default.removeItem(atPath: managementPath)
        let listener = try ManagementListener(path: managementPath)
        defer { listener.close() }
        options += ["--management", managementPath, "unix", "--management-client", "--management-hold", "--management-up-down", "--management-query-passwords"]

        // Trusted binary and DNS hook were verified before the runtime profile
        // was created. Never leave a false orphan marker on signature errors.
        // OpenVPN 2.7 splits this value when CHECKING the script but uses
        // the whole value as a filename when EXECUTING it. Neither raw nor
        // shell-quoted absolute paths containing spaces work in both phases.
        // The checked, root-protected hook parent is the child's cwd; every
        // session/config/socket path remains absolute under the runtime dir.
        options += ["--script-security", "2", "--dns-updown", dnsLaunch.executable]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = options
        task.currentDirectoryURL = dnsLaunch.directory
        try ensureAttempt()
        try dnsRecovery.begin()
        var environment = ProcessInfo.processInfo.environment
        environment["VPNNAV_PRIMARY_SERVICE_UUID"] = dnsRecovery.primaryService
        environment["OPENSSL_CONF"] = "/dev/null"
        task.environment = environment
        let output = Pipe()
        let startupOutput = OpenVPNStartupOutput()
        outputPipe = output
        outputBuffer.removeAll(keepingCapacity: false)
        task.standardOutput = output
        task.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else {
                startupOutput.finish()
                handle.readabilityHandler = nil
                return
            }
            // Startup waits on the session queue. Classify here, before
            // dispatching, so an early exit cannot hide its actual cause.
            startupOutput.receive(bytes)
            self?.queue.async { [weak self, weak task] in
                guard let self, let task, self.process === task else { return }
                self.consumeLog(bytes)
            }
        }
        task.terminationHandler = { [weak self, weak task] _ in
            self?.queue.async { [weak self] in
                guard let self, let task, self.process === task else { return }
                if self.state != .stopping && self.state != .failed,
                   self.scheduleGuardedReconnect() { return }
                if self.state != .stopping && self.state != .failed {
                    self.eventStore.append(.unexpectedExit)
                    self.lastError = "OpenVPN 意外退出，请查看诊断报告。"
                }
                let failure = self.lastError
                self.stop()
                if self.state == .disconnected, let failure {
                    self.state = .failed; self.lastError = failure; self.message = failure
                }
            }
        }
        activeMode = mode
        activeProfileID = profileID
        traffic = nil
        lastError = nil
        failureCode = nil
        process = task
        state = .connecting
        message = "OpenVPN is starting"
        do {
            try ensureAttempt()
            try task.run()
            eventStore.append(.starting)
            startAttemptDeadline()
            let record = try OrphanProcessRecord(pid: task.processIdentifier)
            try JSONEncoder().encode(record).write(to: orphanRecordFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: orphanRecordFile.path)
            let socket = ManagementSocket()
            if validated.requestsCredentials {
                socket.setCredentials(username: username, password: password)
            }
            socket.onChallenge = { [weak self, weak socket] challenge in
                self?.queue.async { [weak self] in
                    guard let self, let socket, self.management === socket else { return }
                    self.challenge = challenge
                    self.state = .authenticating
                    self.message = "需要额外认证，请在主窗口输入。"
                }
            }
            socket.onAuthenticationFailure = { [weak self, weak socket] in
                self?.queue.async { [weak self] in
                    guard let self, let socket, self.management === socket else { return }
                    self.stop()
                    self.eventStore.append(.authentication)
                    self.failureCode = .authentication
                    self.lastError = DiagnosticCode.authentication.summary
                    self.state = .failed
                    self.message = self.lastError ?? "Authentication failed"
                }
            }
            socket.onUnsupportedChallenge = { [weak self, weak socket] in
                self?.queue.async { [weak self] in
                    guard let self, let socket, self.management === socket else { return }
                    self.stop()
                    self.failureCode = .authentication
                    self.lastError = "OpenVPN requested an unsupported authentication method."
                    self.state = .failed
                    self.message = self.lastError ?? "Authentication failed"
                }
            }
            socket.onExit = { [weak self, weak socket] in
                self?.queue.async { [weak self] in
                    // A retired weak socket and management can both be nil.
                    // Bind the socket before comparing identities so a stale
                    // EOF cannot overwrite an explicit successful disconnect.
                    guard let self, let socket, self.management === socket else { return }
                    // EOF can arrive before Process.terminationHandler. Keep
                    // the unexpected failure visible after successful cleanup.
                    let failure = self.lastError ?? "OpenVPN 意外退出，请查看诊断报告。"
                    self.eventStore.append(.unexpectedExit)
                    self.stop()
                    if self.state == .disconnected {
                        self.lastError = failure
                        self.state = .failed
                        self.message = failure
                    }
                }
            }
            socket.onTraffic = { [weak self, weak socket] sample in
                self?.queue.async { [weak self] in
                    guard let self, let socket, self.management === socket else { return }
                    self.traffic = sample
                }
            }
            socket.onState = { [weak self, weak socket] snapshot in
                self?.queue.async { [weak self] in
                    guard let self, let socket, self.management === socket else { return }
                    self.handle(snapshot)
                }
            }
            management = socket
            // The private listener exists before child launch. A lost controller
            // connection makes OpenVPN terminate itself, without signaling a
            // numeric PID after a helper crash. Accept is bounded/cancellable.
            try ManagementStartup.wait(socket: socket, listener: listener,
                process: task, output: startupOutput, check: { try self.ensureAttempt() })
        } catch {
            // stop() deliberately clears old failures for an explicit
            // disconnect. Preserve this attempt's startup cause AFTER cleanup,
            // while retaining any more serious unresolved recovery state.
            stop()
            if let startup = error as? OpenVPNStartupError {
                failureCode = startup.code
                eventStore.append(startup.code)
                if state == .disconnected {
                    lastError = startup.localizedDescription
                    state = .failed
                    message = startup.localizedDescription
                }
            }
            throw error
        }
    }
    @discardableResult
    private func scheduleGuardedReconnect() -> Bool {
        guard let context = reconnectContext,
              let delay = retryBudget.nextDelay(guardVerified: packetGuard.active, optedIn: preferences.reconnectManaged) else { return false }
        do { try packetGuard.verify() } catch { return false }
        // Keep PF installed while the old child exits, DNS is restored and
        // owned routes roll back. Only a new root-owned start may reuse it.
        stop(preservingReconnectContext: true)
        guard process == nil, !dnsRecovery.exists,
              !FileManager.default.fileExists(atPath: workdir.appendingPathComponent("routes.journal").path),
              packetGuard.active else { return false }
        state = .reconnecting
        message = "断线保护保留，\(delay) 秒后尝试重连（\(retryBudget.attempts)/3）"
        activeProfileID = context.profileID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .reconnecting, self.reconnectContext != nil else { return }
            self.retryWork = nil
            let ruleText = RoutingRuleBundle(ipv4: (self.rules?.routes ?? []).map(\.description).joined(separator: "\n"), ipv6: self.rules6.map { $0.routes.map(\.description).joined(separator: "\n") }).json
            do {
                try self.start(profile: context.profile, profileID: context.profileID,
                    mode: context.mode, ruleText: ruleText, username: context.username,
                    password: context.password, preferences: self.preferences, reusingGuard: true, attemptID: context.attemptID)
            } catch {
                self.state = .failed; self.lastError = error.localizedDescription
                self.message = "安全重连未成功，保护保留：" + error.localizedDescription
            }
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
        return true
    }

    func submitChallenge(id: String, response: String) throws {
        guard challenge?.id.uuidString == id, state == .authenticating, let management else { throw ChallengeResponseError.stale }
        try management.respond(id: id, response: response)
        challenge = nil
    }

    private func ensureAttempt() throws {
        guard !cancellationRequested else { throw CancellationError() }
        if attemptExpired { eventStore.append(.timeout); throw TunnelError.connectionTimedOut }
    }
    private func completeAttempt() {
        attemptExpiresAt = nil
        attemptTimer?.cancel(); attemptTimer = nil
    }

    private func startAttemptDeadline() {
        // One total deadline per attempt. Repeated RECONNECTING messages must
        // not postpone it indefinitely.
        guard attemptTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = attemptExpiresAt.map { $0 > now ? $0 - now : 0 } ?? UInt64(preferences.connectionTimeout) * 1_000_000_000
        timer.schedule(deadline: .now() + .nanoseconds(Int(remaining)))
        timer.setEventHandler { [weak self] in
            guard let self, self.state != .connected else { return }
            self.eventStore.append(.timeout)
            self.failureCode = .timeout
            self.stop()
            self.lastError = DiagnosticCode.timeout.summary
            self.state = .failed
            self.message = DiagnosticCode.timeout.summary
        }
        attemptTimer = timer; timer.resume()
    }

    private func consumeLog(_ data: Data) {
        // Bound even a hostile/very verbose engine line. Raw data is transient
        // and discarded; only predefined failure categories are persisted.
        outputBuffer.append(data.prefix(32_768))
        if outputBuffer.count > 65_536 { outputBuffer.removeAll(); return }
        while let end = outputBuffer.firstIndex(of: 10) {
            let line = String(decoding: outputBuffer[..<end], as: UTF8.self)
            outputBuffer.removeSubrange(...end)
#if VPNNAV_LOCAL_TEST
            CIDNSHookTrace.record(line)
#endif
            if let status = ManagedDNSPolicy.hookExitStatus(in: line), status != 0 {
                let reason = DiagnosticCode.dns.summary + " (hook status \(status))"
                stop(); lastError = reason; state = .failed; message = reason
                failureCode = .dns; eventStore.append(.dns)
                return
            }
            if let code = OpenVPNLogClassifier.classify(line) { eventStore.append(code); failureCode = code }
        }
    }

    private func checkIPv6Bypass() throws {
        // The IPv6 policy must never treat a failed command as absence of
        // IPv6. In dual-stack networks a physical IPv6 default bypasses
        // an IPv4-only VPN split policy.
        let routes: String
        do {
            routes = try RouteExecutor.command("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
        } catch {
            throw TunnelError.ipv6CheckUnavailable
        }
        switch IPv6RouteSafety.evaluate(routes) {
        case .noDefaultRoute, .linkLocalOnly: return
        case .tunnelOnly:
            let interfaces: String
            do { interfaces = try RouteExecutor.command("/sbin/ifconfig", ["-a"]) }
            catch { throw TunnelError.ipv6CheckUnavailable }
            guard IPv6RouteSafety.evaluate(routes, interfaces: interfaces) == .linkLocalOnly else { throw TunnelError.ipv6TunnelConflict }
        case .physicalBypass: throw TunnelError.ipv6Unsafe
        case .unknown: throw TunnelError.ipv6CheckUnavailable
        }
    }
    private func handle(_ snapshot: TunnelSnapshot) {
        if snapshot.state == .failed {
            let failure = "VPN authentication failed: \(snapshot.message)"
            stop()
            lastError = failure
            state = .failed
            message = failure
            return
        }
        if snapshot.state == .reconnecting,
           (TunnelReconnectPolicy.action(for: activeMode) == .stopAndRestoreOnlyAfterExit || !preferences.reconnectOriginal) {
            if scheduleGuardedReconnect() { return }
            // Releasing route ownership while OpenVPN is still reconnecting
            // silently creates a path back to the physical network. Guarded
            // retries require a verified active owner and explicit opt-in.
            stop()
            lastError = "OpenVPN lost its connection. Managed VPN stopped instead of reconnecting with unprotected routing."
            state = .failed
            message = lastError!
            return
        }
        state = snapshot.state
        message = snapshot.message
        if snapshot.state == .connected {
            do {
                guard let localIP = snapshot.localTunnelIPv4 ?? snapshot.localTunnelIPv6,
                      let tunnel = Self.findTunnel(containing: localIP,
                        in: try RouteExecutor.command("/sbin/ifconfig", ["-a"])) else { throw DNSJournalError.unavailable }
                try dnsRecovery.confirm(tunnel: tunnel)

            } catch {
                stop(); lastError = error.localizedDescription
                state = .failed; message = error.localizedDescription
                return
            }
            attemptTimer?.cancel(); attemptTimer = nil
            if activeMode == .original {
                do { try ensureAttempt(); completeAttempt(); failureCode = nil; ipStack = snapshot.localTunnelIPv4 != nil ? (snapshot.localTunnelIPv6 != nil ? .dual : .ipv4) : .ipv6; eventStore.append(.connected) }
                catch { stop(); lastError = error.localizedDescription; state = .failed; message = error.localizedDescription }
            }
        } else if snapshot.state == .reconnecting {
            if attemptExpiresAt == nil { attemptExpiresAt = DispatchTime.now().uptimeNanoseconds + UInt64(preferences.connectionTimeout) * 1_000_000_000 }
            startAttemptDeadline()
        }
        guard snapshot.state == .connected, activeMode != .original, routing == nil else { return }
        state = .connecting
        message = "正在应用并核验 IPv4／IPv6 路由"
        do {
            guard let remote = snapshot.remoteIPv4 ?? snapshot.remoteIPv6,
                  let localIP = snapshot.localTunnelIPv4 ?? snapshot.localTunnelIPv6,
                  let utun = Self.findTunnel(containing: localIP, in: try RouteExecutor.command("/sbin/ifconfig", ["-a"])) else { throw DualStackError.missingTunnel }
            let has4 = snapshot.localTunnelIPv4 != nil, has6 = snapshot.localTunnelIPv6 != nil
            if preferences.requireDualStack == true && (!has4 || !has6) { throw DualStackError.requireDualStack }
            if !preferences.killSwitch {
                if !has6 { try checkIPv6Bypass() }
                if !has4 { throw DualStackError.unsafeFallback }
            }
            let paths = try physicalPaths(endpoint: remote), local = try localNetworks(paths: paths)
            let dnsServers = try dnsRecovery.prepareManaged(tunnel: utun, has4: has4, has6: has6)
            managedDNSServers = dnsServers
            domesticDNSServers = SplitDNSPolicy.domesticServers(path4: paths.0 != nil, path6: paths.1 != nil, protectedVPN: dnsServers + [remote])
            let plan = try DualStackRoutePlan.build(endpoint: remote, tunnel: utun, has4: has4, has6: has6,
                path4: paths.0, path6: paths.1, local4: local.0, local6: local.1,
                mode: activeMode, country4: rules, country6: rules6, custom: custom, dnsServers: dnsServers,
                directDNSServers: activeMode == .chinaDirect ? domesticDNSServers : [])
            let executor = RouteExecutor(journal: workdir.appendingPathComponent("routes.journal"), shouldCancel: { [weak self] in self?.cancellationRequested == true || self?.attemptExpired == true })
            routing = executor
            try executor.apply(plan.ipv4, inheriting: Set(plan.dns4)); try executor.applyIPv6(plan.ipv6, inheriting: Set(plan.dns6))
            try verifyManagedRoutes(plan: plan, allCustom: true)
            if let policy = try policy(for: plan) {
                try packetGuard.replaceRules(policy.rules(tunnel: utun)); guardPolicy = policy
                try packetGuard.verify()
            }
            try configureSplitDNS(mode: activeMode, tunnel: utun)
            activePlan = plan; protectedLocalNetworks = local.0
            protectedPhysicalInterface = (IPAddress.isIPv6(remote) ? paths.1 : paths.0)?.interface
            protectedVPNInterface = utun
            try ensureAttempt(); completeAttempt(); routingRevision = UUID(); ipStack = plan.stack
            state = .connected; message = "已连接 · " + activeMode.title + " · " + plan.stack.title
            failureCode = nil; eventStore.append(.connected); startNetworkWatchdog()
        } catch {
            let failure = "Routing failed; VPN stopped for safety: \(error.localizedDescription)"
            stop(); lastError = failure; state = .failed; message = failure
            failureCode = .route; eventStore.append(.route)
        }
    }
    private func configureSplitDNS(mode: RoutingMode, tunnel: String) throws {
        if mode == .chinaDirect {
            let proxy = SplitDNSProxy(domains: try ChinaDNSRules.load(),
                domestic: domesticDNSServers.map { .init(address: $0) },
                vpn: try dnsRecovery.managedGlobalServers().map { .init(address: $0) })
            try proxy.start()
            do { try dnsRecovery.publishManagedResolver(tunnel: tunnel, port: proxy.port) }
            catch { proxy.stop(); throw error }
            splitDNS?.stop(); splitDNS = proxy
        } else {
            try dnsRecovery.publishManagedResolver(tunnel: tunnel, port: nil)
            splitDNS?.stop(); splitDNS = nil
        }
    }
    private func physicalPaths(endpoint: String) throws -> (PhysicalIPPath?, PhysicalIPPath?) {
        func path(_ target: String, ipv6: Bool) throws -> PhysicalIPPath {
            let raw = try RouteExecutor.command("/sbin/route", ["-n", "get"] + (ipv6 ? ["-inet6"] : []) + [target])
            guard let gateway = Self.parseValue("gateway:", in: raw), let iface = Self.parseValue("interface:", in: raw) else { throw TunnelError.noPhysicalGateway }
            return try PhysicalIPPath(gateway: gateway, interface: iface)
        }
        if IPAddress.isIPv6(endpoint) { return (try? path("default", ipv6: false), try path(endpoint, ipv6: true)) }
        return (try path(endpoint, ipv6: false), try? path("default", ipv6: true))
    }
    private func localNetworks(paths: (PhysicalIPPath?, PhysicalIPPath?)) throws -> ([IPv4CIDR], [IPv6CIDR]) {
        let v4 = try RouteExecutor.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        let v6 = try RouteExecutor.command("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
        let local4 = paths.0.map { LocalIPv4Networks.parse(netstat: v4, physicalInterface: $0.interface) } ?? []
        let local6 = paths.1.map { LocalIPv6Networks.parse(netstat: v6, physicalInterface: $0.interface) } ?? []
        if paths.0 != nil && local4.isEmpty { throw TunnelError.noPhysicalGateway }
        return (local4, local6)
    }
    private func policy(for plan: DualStackRoutePlan) throws -> LeakGuardPolicy? {
        guard let old = guardPolicy else { return nil }
        return try LeakGuardPolicy(physical: old.physical, endpoint: plan.endpoint, port: old.port, transport: old.transport,
            local: plan.local4, country: [], managedDirect: plan.direct4.map(\.prefix),
            physical4: plan.path4?.interface, physical6: plan.path6?.interface, local6: plan.local6,
            managedDirect6: plan.direct6.map(\.prefix), ipv4Tunnel: !plan.defaults4.isEmpty, ipv6Tunnel: !plan.defaults6.isEmpty)
    }
    private static func parseValue(_ key: String, in text: String) -> String? {
        text.components(separatedBy: .newlines).first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key) })?
            .components(separatedBy: key).last?.trimmingCharacters(in: .whitespaces)
    }
    private static func findTunnel(containing ip: String, in text: String) -> String? {
        var current: String?
        for line in text.components(separatedBy: .newlines) {
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                let head = line.components(separatedBy: ":").first ?? ""
                current = head.hasPrefix("utun") ? head : nil
            }
            if let current {
                let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if tokens.count >= 2, ["inet", "inet6"].contains(tokens[0]),
                   IPAddress.canonical(String(tokens[1].split(separator: "%")[0])) == IPAddress.canonical(ip) { return current }
            }
        }
        return nil
    }
    private func verifyManagedRoutes(plan: DualStackRoutePlan, allCustom: Bool = false) throws {
        for route in (plan.endpoint4.map { [$0] } ?? []) + plan.dns4 + plan.defaults4 {
            try ensureAttempt()
            let raw = try RouteExecutor.command("/sbin/route", ["-n", "get", "-net", route.prefix.description])
            guard ObservedIPv4Route(commandOutput: raw).isExactly(route) else { throw TunnelError.routeVerificationFailed }
        }
        for route in (plan.endpoint6.map { [$0] } ?? []) + plan.dns6 + plan.defaults6 {
            try ensureAttempt()
            let raw = try RouteExecutor.command("/sbin/route", ["-n", "get", "-inet6", "-net", route.prefix.description])
            guard ObservedIPv6Route(commandOutput: raw).isExactly(route) else { throw TunnelError.routeVerificationFailed }
        }
        func verify(_ ip: String, vpn: Bool) throws {
            let v6 = IPAddress.isIPv6(ip), path = v6 ? plan.path6 : plan.path4
            let raw = try RouteExecutor.command("/sbin/route", ["-n", "get"] + (v6 ? ["-inet6"] : []) + [ip])
            let iface = Self.parseValue("interface:", in: raw) ?? "", gateway = Self.parseValue("gateway:", in: raw) ?? ""
            if vpn { guard iface == plan.tunnel else { throw TunnelError.routeVerificationFailed } }
            else {
                guard let path, iface == path.interface,
                      (v6 ? IPAddress.gateway6(gateway, interface: iface) == IPAddress.gateway6(path.gateway, interface: iface) : gateway == path.gateway) else { throw TunnelError.routeVerificationFailed }
            }
        }
        if let route = plan.direct4.first { try verify(IPv4CIDR.parseAddressString(route.prefix.network), vpn: false) }
        if let route = plan.direct6.first { try verify(route.prefix.address, vpn: false) }
        if !plan.defaults4.isEmpty, let sample = ["8.8.8.8", "1.1.1.1", "9.9.9.9", "208.67.222.222"].first(where: { ip in
            ip != plan.endpoint && !plan.direct4.contains { $0.prefix.contains(IPv4CIDR.parseAddress(ip)!) } && !plan.local4.contains { $0.contains(IPv4CIDR.parseAddress(ip)!) }
        }) { try verify(sample, vpn: true) }
        if !plan.defaults6.isEmpty, let sample = ["2606:4700:4700::1111", "2001:4860:4860::8888", "2620:fe::fe"].first(where: { ip in
            ip != plan.endpoint && !plan.direct6.contains { $0.prefix.contains(ip) } && !plan.local6.contains { $0.contains(ip) }
        }) { try verify(sample, vpn: true) }
        let checks = allCustom ? custom.active : [false, true].flatMap { v6 in CustomRouteAction.allCases.compactMap { action in custom.active.first { $0.action == action && $0.cidr.contains(":") == v6 } } }
        for rule in checks {
            try ensureAttempt()
            let ip = rule.cidr.contains(":") ? try CustomRuleSet.prefix6(rule.cidr).address : IPv4CIDR.parseAddressString(try CustomRuleSet.prefix(rule.cidr).network)
            let protectedDNS = plan.dns4.contains { $0.prefix.contains(IPv4CIDR.parseAddress(ip) ?? 0) } || plan.dns6.contains { $0.prefix.contains(ip) }
            try verify(ip, vpn: protectedDNS || (rule.action == .vpn && !(activeMode == .chinaDirect && domesticDNSServers.contains(ip))))
        }
    }
    func explainRoute(_ request: RouteLookupRequest) throws -> RouteLookupResult {
        guard state == .connected, process?.isRunning == true, activeProfileID == request.profileID,
              activeAttemptID == request.attemptID, routingRevision == request.revision, activeMode == request.mode else { throw RoutingModeSwitchError.stale }
        let plan = activePlan, v6 = IPAddress.isIPv6(request.ip)
        let decision = try RouteExplanation.decide(ip: request.ip, mode: activeMode, country: rules, custom: custom,
            local: plan?.local4 ?? [], endpoint: plan?.endpoint, effectiveDirect: plan?.direct4.map(\.prefix),
            country6: rules6, local6: plan?.local6 ?? [], effectiveDirect6: plan?.direct6.map(\.prefix),
            available: plan.map { v6 ? !$0.defaults6.isEmpty : !$0.defaults4.isEmpty },
            directDNS: activeMode == .chinaDirect ? domesticDNSServers : [],
            protectedDNS: (plan?.dns4.map { $0.prefix.description.split(separator: "/")[0].description } ?? []) + (plan?.dns6.map { $0.prefix.address } ?? []))
        let args = ["-n", "get"] + (v6 ? ["-inet6"] : []) + [request.ip]
        let raw = decision.path == .blocked ? (try? RouteExecutor.command("/sbin/route", args)) ?? "" : try RouteExecutor.command("/sbin/route", args)
        let observed = Self.parseValue("interface:", in: raw) ?? "", gateway = Self.parseValue("gateway:", in: raw) ?? ""
        let physical = v6 ? plan?.path6 : plan?.path4
        let expected: String? = decision.path == .vpn ? plan?.tunnel : decision.path == .direct ? physical?.interface : nil
        var matches = expected.map { !$0.isEmpty && $0 == observed }
        let local = v6 ? plan?.local6.contains { $0.contains(request.ip) } == true : plan?.local4.contains { $0.contains(IPv4CIDR.parseAddress(request.ip)!) } == true
        if decision.path == .direct, !local, let physical {
            matches = matches == true && (v6 ? IPAddress.gateway6(gateway, interface: observed) == physical.gateway : gateway == physical.gateway)
        }
        return RouteLookupResult(request: request, decision: decision, expectedInterface: expected,
            observedInterface: observed, observedGateway: gateway, matchesExpected: matches)
    }
    private func verifyManagedEnvironment() throws {
        guard let plan = activePlan else { throw TunnelError.noActiveRoutePlan }
        try dnsRecovery.confirm(tunnel: plan.tunnel)
        try splitDNS?.verify()
        if packetGuard.active { try packetGuard.verify() }
        else { if plan.defaults6.isEmpty { try checkIPv6Bypass() }; if plan.defaults4.isEmpty { throw DualStackError.unsafeFallback } }
        for (v6, path) in [(false, plan.path4), (true, plan.path6)] {
            guard let path else {
                if let found = try? RouteExecutor.command("/sbin/route", ["-n", "get"] + (v6 ? ["-inet6"] : []) + ["default"]),
                   let iface = Self.parseValue("interface:", in: found), LeakGuardPolicy.validPhysical(iface) {
                    throw TunnelError.noPhysicalGateway
                }
                continue
            }
            let observed = try RouteExecutor.command("/sbin/route", ["-n", "get"] + (v6 ? ["-inet6"] : []) + ["default"])
            guard Self.parseValue("interface:", in: observed) == path.interface,
                  let gateway = Self.parseValue("gateway:", in: observed),
                  (v6 ? IPAddress.gateway6(gateway, interface: path.interface) == path.gateway : gateway == path.gateway) else { throw TunnelError.noPhysicalGateway }
        }
        let local = try localNetworks(paths: (plan.path4, plan.path6))
        guard Set(local.0) == Set(plan.local4), Set(local.1) == Set(plan.local6) else { throw TunnelError.noPhysicalGateway }
        try verifyManagedRoutes(plan: plan)
    }

    private func startNetworkWatchdog() {
        networkWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: .seconds(5))
        timer.setEventHandler { [weak self] in self?.verifyPhysicalNetwork() }
        networkWatchdog = timer
        timer.resume()
    }

    func verifyPhysicalNetwork() {
        guard state == .connected, activeMode != .original, !cancellationRequested else { return }
        do {
            try verifyManagedEnvironment()
        } catch {
            if cancellationRequested { stop(releaseProtection: true); return }
            eventStore.append(.networkChanged)
            failureCode = .networkChanged
            if scheduleGuardedReconnect() { return }
            let failure = "Network route/IPv6 protection changed; VPN disconnected: \(error.localizedDescription)"
            stop()
            lastError = failure
            state = .failed
            message = failure
        }
    }

    func retryRouteRecovery() -> String {
        eventStore.append(.recovery)
        guard process == nil else {
            return "ERROR: Disconnect the current VPN before recovering routes."
        }
        let orphanProfile = workdir.appendingPathComponent("active.ovpn")
        if FileManager.default.fileExists(atPath: orphanProfile.path) ||
           FileManager.default.fileExists(atPath: orphanRecordFile.path) {
            // Refuse any automatic kill. Only ESRCH conclusively tells us the
            // recorded child PID is no longer active. PID reuse is blocked.
            guard let bytes = try? Data(contentsOf: orphanRecordFile),
                  let record = try? JSONDecoder().decode(OrphanProcessRecord.self, from: bytes),
                  record.pid > 1 else {
                return "ERROR: A previous session has no trustworthy process record."
            }
            errno = 0
            let result = Darwin.kill(record.pid, 0)
            guard OrphanProcessRecovery.canClearStaleMarker(
                pidRecordPresent: true,
                pidConfirmedAbsent: result == -1 && errno == ESRCH) else {
                return "ERROR: The previous process PID still exists or cannot be verified. No signals were sent."
            }
            // The exact prior child PID no longer exists, so no process can be
            // using that identity. Any unfinished route operation remains gated
            // by the independent durable route journal.
            do {
                try FileManager.default.removeItem(at: orphanRecordFile)
                if FileManager.default.fileExists(atPath: orphanProfile.path) {
                    try FileManager.default.removeItem(at: orphanProfile)
                }
                let staleSocket = workdir.appendingPathComponent("management.sock")
                try? FileManager.default.removeItem(at: staleSocket)
            } catch {
                return "ERROR: Cannot clear verified stale process markers: \(error.localizedDescription)"
            }
        }
        do { try dnsRecovery.restore() }
        catch { state = .failed; message = error.localizedDescription; return "ERROR: " + message }
        let journal = workdir.appendingPathComponent("routes.journal")
        guard FileManager.default.fileExists(atPath: journal.path) else {
            do { try packetGuard.release(); guardPolicy = nil; reconnectContext = nil }
            catch { state = .failed; message = error.localizedDescription; return "ERROR: " + message }
            lastError = nil
            state = .disconnected
            message = "已核验旧进程退出，DNS、路由与本应用断线保护已恢复。"
            return message
        }
        do { try RouteJournalRecovery.reconcileAbsentAdds(journal) }
        catch { state = .failed; message = error.localizedDescription; return "ERROR: " + message }
        _ = RouteExecutor(journal: journal)
        if FileManager.default.fileExists(atPath: journal.path) {
            state = .failed
            message = "Route recovery is incomplete; some routes could not be safely verified."
            return "ERROR: \(message)"
        }
        do { try packetGuard.release(); guardPolicy = nil; reconnectContext = nil }
        catch { state = .failed; message = error.localizedDescription; return "ERROR: " + message }
        lastError = nil
        state = .disconnected
        message = "DNS、路由与本应用断线保护已安全恢复。"
        return message
    }
    func changeRules(_ text: String) throws {
        guard state == .connected, process?.isRunning == true, activeMode == .chinaDirect, let oldRules = rules,
              activePlan != nil, routing != nil else { throw TunnelError.noActiveRoutePlan }
        let bundle = try RoutingRuleBundle.decoded(text)
        let next = try RuleSet(text: bundle.ipv4)
        guard next.routes.count >= 100 else { throw TunnelError.missingRules }
        try RuleUpdater.validateChange(previous: oldRules, next: next)
        if let text6 = bundle.ipv6, let old6 = rules6 { try IPv6RuleSet.validateChange(previous: old6, next: IPv6RuleSet(text: text6)) }
        try transitionManagedRoutes(to: .chinaDirect, ruleText: text)
    }
    func switchRoutingMode(to mode: RoutingMode, ruleText: String) throws {
        guard state == .connected, process?.isRunning == true, activeMode != .original,
              mode != .original, activePlan != nil, routing != nil else { throw RoutingModeSwitchError.unavailable }
        guard mode != activeMode else { return }
        try transitionManagedRoutes(to: mode, ruleText: ruleText)
    }
    private func transitionManagedRoutes(to mode: RoutingMode, ruleText: String) throws {
        guard let old = activePlan, let executor = routing else { throw TunnelError.noActiveRoutePlan }
        let bundle = try RoutingRuleBundle.decoded(ruleText)
        let next4 = mode == .chinaDirect ? try RuleSet(text: bundle.ipv4) : nil
        let next6 = mode == .chinaDirect ? try bundle.ipv6.map { try IPv6RuleSet(text: $0) } ?? rules6 : nil
        if let next4, next4.routes.count < 100 { throw TunnelError.missingRules }
        if let next6, next6.routes.count < 100 { throw DualStackError.missingRules }
        let plan = try DualStackRoutePlan.build(endpoint: old.endpoint, tunnel: old.tunnel,
            has4: !old.defaults4.isEmpty, has6: !old.defaults6.isEmpty, path4: old.path4, path6: old.path6,
            local4: old.local4, local6: old.local6, mode: mode, country4: next4, country6: next6, custom: custom,
            dnsServers: managedDNSServers, directDNSServers: mode == .chinaDirect ? domesticDNSServers : [])
        let nextProtection = try policy(for: plan)
        do {
            try ensureAttempt(); try verifyManagedEnvironment()
            try DualStackTransitionExecutor.apply(from: old, to: plan, executor: executor, updateProtection: { tightens in
                if let nextProtection { try self.packetGuard.replaceRules(nextProtection.rules(tunnel: plan.tunnel), resetExistingStates: tightens); self.guardPolicy = nextProtection }
            }, verify: { try self.ensureAttempt(); try self.verifyManagedRoutes(plan: plan, allCustom: true) })
            try ensureAttempt(); guard process?.isRunning == true else { throw RoutingModeSwitchError.stale }
            try configureSplitDNS(mode: mode, tunnel: plan.tunnel)
            activePlan = plan; rules = next4; rules6 = next6; activeMode = mode; routingRevision = UUID()
            if let context = reconnectContext { reconnectContext = ReconnectContext(profile: context.profile, profileID: context.profileID,
                attemptID: context.attemptID, mode: mode, username: context.username, password: context.password) }
            message = "已连接 · " + mode.title + " · " + plan.stack.title
        } catch {
            let cause = error.localizedDescription; stop()
            let pending = networkRecoveryRequired || process?.isRunning == true
            let reason = (pending ? "双栈路由切换失败，恢复未完成：" : "双栈路由切换失败，VPN 已断开：") + cause
            lastError = reason; state = .failed; message = reason; throw error
        }
    }
    func stop(releaseProtection: Bool = false, preservingReconnectContext: Bool = false) {
        releaseProtectionOnExit = releaseProtectionOnExit || releaseProtection
        retryWork?.cancel(); retryWork = nil
        if !preservingReconnectContext { reconnectContext = nil }
        if packetGuard.active, let policy = guardPolicy {
            do {
                try packetGuard.replaceRules(policy.rules(tunnel: nil))
                protectionTeardownBlocked = false
            } catch { protectionTeardownBlocked = true }
        }
        attemptTimer?.cancel(); attemptTimer = nil
        attemptExpiresAt = nil
        // A restarted helper has no Process identity for an orphaned child.
        // A plain Disconnect must never erase the very evidence that prevents
        // route rollback and a competing tunnel. Recovery checks PID absence.
        if process == nil && !TunnelShutdownPolicy.mayFinalizeSessionCleanup(
            ownedChildProcess: false, childExited: false,
            hasPersistentSessionEvidence: hasPersistentSessionEvidence) {
            state = .failed
            message = "Previous OpenVPN session is unverified. Use Safe Network Recovery; Disconnect cannot clear its evidence."
            return
        }
        networkWatchdog?.cancel()
        networkWatchdog = nil
        lastError = nil
        state = .stopping
        message = "Stopping OpenVPN before restoring network routes"
        challenge = nil
        management?.close()
        management = nil

        // Releasing /1 VPN routes while OpenVPN is still running may expose
        // connections over the physical default gateway. Terminate the child
        // before restoring routes, and never erase crash evidence on uncertainty.
        if let task = process, task.isRunning {
            task.terminate()
            let gracefulDeadline = Date().addingTimeInterval(2.0)
            while task.isRunning && Date() < gracefulDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // Do not send SIGKILL to a numeric PID from a delayed callback:
            // PID reuse could target an unrelated process. Process.terminate()
            // targets the child object, and an unresolved child is kept as
            // recovery evidence rather than force-killed.
            if task.isRunning {
                lastError = "OpenVPN did not exit after graceful termination. Routes and session marker were retained; inspect the child before retrying."
                state = .failed
                message = lastError!
                return
            }
        }
        stopRoutesAndReset()
    }

    private func stopRoutesAndReset() {
        // Invoked by both explicit disconnect and a natural process-exit
        // callback. A stale callback must never restore routes for a live VPN.
        guard TunnelShutdownPolicy.mayRestoreRoutes(openVPNExited: process?.isRunning != true),
              TunnelShutdownPolicy.mayFinalizeSessionCleanup(
                ownedChildProcess: process != nil,
                childExited: process?.isRunning != true,
                hasPersistentSessionEvidence: hasPersistentSessionEvidence) else {
            state = .failed
            message = "OpenVPN exit or ownership is unverified; preserving routes and session evidence."
            return
        }
        if protectionTeardownBlocked && !releaseProtectionOnExit {
            process = nil; activeProfileID = nil; traffic = nil
            state = .failed
            message = "断线保护无法核验，DNS 与路由恢复记录已保留。请执行安全网络恢复。"
            return
        }
        // Natural child exit may reach here before the management socket's
        // EOF callback. Disable its stale callbacks and stop the watchdog.
        networkWatchdog?.cancel()
        networkWatchdog = nil
        challenge = nil
        management?.close()
        management = nil
        attemptTimer?.cancel(); attemptTimer = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? outputPipe?.fileHandleForReading.close()
        outputPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
        eventStore.append(.stopped)
        do { try dnsRecovery.restore() }
        catch { lastError = error.localizedDescription; eventStore.append(.dns) }
        splitDNS?.stop(); splitDNS = nil
        domesticDNSServers = []; managedDNSServers = []
        routing?.rollback()
        routing = nil
        activePlan = nil; ipStack = nil
        protectedLocalNetworks = []
        protectedPhysicalInterface = nil
        protectedVPNInterface = nil
        routingRevision = nil
        process = nil
        activeProfileID = nil
        traffic = nil
        let unresolved = FileManager.default.fileExists(
            atPath: workdir.appendingPathComponent("routes.journal").path)
        if releaseProtectionOnExit && !unresolved && !dnsRecovery.exists {
            do { try packetGuard.release(); guardPolicy = nil; reconnectContext = nil }
            catch { lastError = error.localizedDescription }
        }
        let protectionPending = packetGuard.requiresRecovery
        state = unresolved || dnsRecovery.exists || protectionPending || lastError != nil ? .failed : .disconnected
        message = unresolved ?
            "OpenVPN exited, but some routes still require manual recovery." :
            (lastError ?? (protectionPending ? "VPN 已停止，断线保护保留。点击断开或安全恢复以解除。" : "Disconnected"))
        // The active profile is only cleared once the child is known to have
        // stopped. A persistent route journal independently blocks reconnect.
        for name in ["active.ovpn", "management.sock", "auth.txt", "openvpn-child.json"] {
            try? FileManager.default.removeItem(at: workdir.appendingPathComponent(name))
        }
    }
}
enum TunnelError: Error, LocalizedError {
    case needRoot, alreadyRunning, missingRules, badCredential, engineMissing,
         managementUnavailable, connectionTimedOut, noPhysicalGateway, noTunnelInterface, noActiveRoutePlan, ipv6Unsafe, ipv6CheckUnavailable, ipv6TunnelConflict, unresolvedRoutes, routeVerificationFailed, orphanedSession

    var errorDescription: String? {
        switch self {
        case .ipv6CheckUnavailable: return L10n.text("无法完整核验 IPv6 路由与接口地址，连接已停止。请查看网络诊断后重试。")
        case .ipv6TunnelConflict: return L10n.text("发现其它 IPv6 隧道路由，尚不能排除旁路。请关闭其它 VPN／TUN，或启用断线保护后重试。")
        case .ipv6Unsafe: return "服务器没有建立 IPv6 隧道，但系统仍有 IPv6 出口。请启用断线保护或使用支持双栈的服务器。"
        case .engineMissing: return "Signed OpenVPN engine is not installed."
        case .needRoot: return "Approve the privileged helper in macOS."
        case .alreadyRunning: return "Another VPN session is active."
        case .missingRules: return "A valid China IPv4 rules snapshot is required."
        case .badCredential: return "Username/password is missing or invalid."
        case .connectionTimedOut: return DiagnosticCode.timeout.summary
        case .managementUnavailable: return "OpenVPN management socket is unavailable."
        case .noPhysicalGateway: return "Cannot identify the local physical gateway."
        case .noTunnelInterface: return "Cannot verify the OpenVPN utun interface."
        case .noActiveRoutePlan: return "No active split-routing session."
        case .unresolvedRoutes: return "Unresolved routes remain from an earlier session. Diagnose and safely restore them before reconnecting."
        case .orphanedSession: return "An OpenVPN session was left by a helper crash. Verify the old process before reconnecting."
        case .routeVerificationFailed: return "macOS route lookup does not match the requested VPN policy."
        }
    }
}

