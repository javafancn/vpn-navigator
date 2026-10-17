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
    private let packetGuard = PacketFilterGuard()
    private var guardPolicy: LeakGuardPolicy?
    private var releaseProtectionOnExit = false
    private var protectionTeardownBlocked = false
    var firewallActive: Bool { packetGuard.active }
    var firewallRecoveryRequired: Bool { packetGuard.requiresRecovery }
    private var activeMode: RoutingMode = .original
    private(set) var activeProfileID: UUID?
    private var rules: RuleSet?
    private var activePlan: RoutePlan?
    private var protectedLocalNetworks: [IPv4CIDR] = []
    private var protectedPhysicalInterface: String?
    private var protectedVPNInterface: String?
    private var fullVPNEndpointIPv4: String?
    private var fullVPNGateway: String?
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
        self.activeAttemptID = attemptID
        self.cancellationGeneration = capturedGeneration
        self.preferences = preferences
        var validated = try ProfileSafety.validate(text)
        try ManagedRoutingPolicy.validate(validated, mode: mode)
        // IPv4-only routing cannot protect IPv6. Refuse a non-original split or
        // full-VPN mode while native IPv6 has a non-tunnel path (fail closed).
        if mode != .original && !preferences.killSwitch { try checkIPv6Bypass() }
        if mode == .chinaDirect {
            rules = try RuleSet(text: ruleText)
            guard let rules, rules.routes.count >= 100 else { throw TunnelError.missingRules }
        }
        guard ManagementCredentialPolicy.allows(
            username: username, password: password,
            credentialsRequired: validated.requestsCredentials) else { throw TunnelError.badCredential }
        // Resolve and verify both required signed components before creating
        // any root-owned session markers or credentials.
        let binary = try ExecutableTrust.trustedOpenVPN().path
        let dnsHook = try ExecutableTrust.trustedDNSUpDown()
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
            if let raw = IPv4CIDR.parseAddress(endpoint.host) { numeric = IPv4CIDR.parseAddressString(raw) }
            else {
                let answer = try RouteExecutor.command("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", endpoint.host])
                guard let resolved = Self.parseValue("ip_address:", in: answer), IPv4CIDR.parseAddress(resolved) != nil else { throw LeakGuardError.invalid }
                numeric = resolved
            }
            let path = try RouteExecutor.command("/sbin/route", ["-n", "get", numeric])
            guard let physical = Self.parseValue("interface:", in: path), LeakGuardPolicy.validPhysical(physical) else { throw TunnelError.noPhysicalGateway }
            let table = try RouteExecutor.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
            let local = LocalIPv4Networks.parse(netstat: table, physicalInterface: physical)
            let policy = try LeakGuardPolicy(physical: physical, endpoint: numeric, port: endpoint.port,
                transport: endpoint.transport, local: local, country: mode == .chinaDirect ? rules?.routes ?? [] : [])
            validated = try ProfileSafety.validate(endpoint.pinnedProfile(validated.text, address: numeric))
            if reusingGuard { try packetGuard.replaceRules(policy.rules(tunnel: nil), resetExistingStates: true) }
            else { try packetGuard.activate(policy.rules(tunnel: nil)) }
            guardPolicy = policy
            reconnectContext = ReconnectContext(profile: validated.text, profileID: profileID, attemptID: attemptID, mode: mode, username: username, password: password)
        }
        try validated.text.write(to: configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        var options = ["--config", configFile.path]
        options += ManagedRoutingPolicy.openVPNArguments(mode: mode)
        let managementPath = workdir.appendingPathComponent("management.sock").path
        try? FileManager.default.removeItem(atPath: managementPath)
        options += ["--management", managementPath, "unix", "--management-hold", "--management-up-down", "--management-query-passwords"]

        // Trusted binary and DNS hook were verified before the runtime profile
        // was created. Never leave a false orphan marker on signature errors.
        options += ["--script-security", "2", "--dns-updown", dnsHook.path]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = options
        task.currentDirectoryURL = workdir
        try dnsRecovery.begin()
        var environment = ProcessInfo.processInfo.environment
        environment["VPNNAV_PRIMARY_SERVICE_UUID"] = dnsRecovery.primaryService
        environment["OPENSSL_CONF"] = "/dev/null"
        task.environment = environment
        let output = Pipe()
        outputPipe = output
        outputBuffer.removeAll(keepingCapacity: false)
        task.standardOutput = output
        task.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { handle.readabilityHandler = nil; return }
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
        process = task
        state = .connecting
        message = "OpenVPN is starting"
        do {
            guard !cancellationRequested else { throw CancellationError() }
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
                    guard let self, self.management === socket else { return }
                    self.challenge = challenge
                    self.state = .authenticating
                    self.message = "需要额外认证，请在主窗口输入。"
                }
            }
            socket.onAuthenticationFailure = { [weak self, weak socket] in
                self?.queue.async { [weak self] in
                    guard let self, self.management === socket else { return }
                    self.stop()
                    self.eventStore.append(.authentication)
                    self.lastError = DiagnosticCode.authentication.summary
                    self.state = .failed
                    self.message = self.lastError ?? "Authentication failed"
                }
            }
            socket.onUnsupportedChallenge = { [weak self, weak socket] in
                self?.queue.async { [weak self] in
                    guard let self, self.management === socket else { return }
                    self.stop()
                    self.lastError = "OpenVPN requested an unsupported authentication method."
                    self.state = .failed
                    self.message = self.lastError ?? "Authentication failed"
                }
            }
            socket.onExit = { [weak self, weak socket] in
                self?.queue.async { [weak self] in
                    guard let self, self.management === socket else { return }
                    self.stop()
                }
            }
            socket.onTraffic = { [weak self, weak socket] sample in
                self?.queue.async { [weak self] in
                    guard let self, self.management === socket else { return }
                    self.traffic = sample
                }
            }
            socket.onState = { [weak self, weak socket] snapshot in
                self?.queue.async { [weak self] in
                    guard let self, self.management === socket else { return }
                    self.handle(snapshot)
                }
            }
            management = socket
            // OpenVPN creates the socket asynchronously. Bounded retry only.
            var success = false
            for _ in 0..<50 {
                guard !cancellationRequested else { throw CancellationError() }
                if (try? socket.open(path: managementPath)) != nil { success = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard success else { throw TunnelError.managementUnavailable }
        } catch {
            stop()
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
            let ruleText = (self.rules?.routes ?? []).map(\.description).joined(separator: "\n")
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

    private func startAttemptDeadline() {
        // One total deadline per attempt. Repeated RECONNECTING messages must
        // not postpone it indefinitely.
        guard attemptTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(preferences.connectionTimeout))
        timer.setEventHandler { [weak self] in
            guard let self, self.state != .connected else { return }
            self.eventStore.append(.timeout)
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
            if let code = OpenVPNLogClassifier.classify(line) { eventStore.append(code) }
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
            throw TunnelError.ipv6Unsafe
        }
        switch IPv6RouteSafety.evaluate(routes) {
        case .noDefaultRoute: return
        case .tunnelOnly, .physicalBypass, .unknown: throw TunnelError.ipv6Unsafe
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
                guard let localIP = snapshot.localTunnelIPv4,
                      let tunnel = Self.findTunnel(containing: localIP,
                        in: try RouteExecutor.command("/sbin/ifconfig", ["-a"])) else { throw DNSJournalError.unavailable }
                try dnsRecovery.confirm(tunnel: tunnel)
                if let guardPolicy { try packetGuard.replaceRules(guardPolicy.rules(tunnel: tunnel)) }
            } catch {
                stop(); lastError = error.localizedDescription
                state = .failed; message = error.localizedDescription
                return
            }
            attemptTimer?.cancel(); attemptTimer = nil
            if activeMode == .original { eventStore.append(.connected) }
        } else if snapshot.state == .reconnecting {
            startAttemptDeadline()
        }
        if snapshot.state == .connected && activeMode == .chinaDirect {
            state = .connecting
            message = "Applying and validating China IPv4 routes"
        }
        if snapshot.state == .connected, activeMode == .fullVPN {
            do {
                guard let remote = snapshot.remoteIPv4,
                      let localIP = snapshot.localTunnelIPv4 else {
                    throw TunnelError.routeVerificationFailed
                }
                let interfaces = try RouteExecutor.command("/sbin/ifconfig", ["-a"])
                guard let expectedTunnel = Self.findTunnel(containing: localIP, in: interfaces) else {
                    throw TunnelError.noTunnelInterface
                }
                try verifyForeignVPNRoute(knownTunnel: expectedTunnel)
                let endpoint = try RouteExecutor.command("/sbin/route", ["-n", "get", remote])
                guard let physical = Self.parseValue("interface:", in: endpoint),
                      physical.hasPrefix("en"),
                      let gateway = Self.parseValue("gateway:", in: endpoint),
                      !gateway.isEmpty else { throw TunnelError.noPhysicalGateway }
                protectedVPNInterface = expectedTunnel
                protectedPhysicalInterface = physical
                fullVPNEndpointIPv4 = remote
                fullVPNGateway = gateway
                state = .connected
                message = "Connected · global VPN route verified"
                eventStore.append(.connected)
                startNetworkWatchdog()
            } catch {
                let reason = "Full VPN routing is not active: \(error.localizedDescription)"
                stop()
                lastError = reason
                state = .failed
                message = reason
            }
            return
        }
        guard snapshot.state == .connected, activeMode == .chinaDirect, routing == nil else { return }
        guard let remote = snapshot.remoteIPv4, let tunnelIP = snapshot.localTunnelIPv4, let rules else {
            let failure = "OpenVPN did not report a usable IPv4 endpoint or tunnel address."
            stop()
            lastError = failure
            state = .failed
            message = failure
            return
        }
        do {
            // Physical gateway is determined BEFORE a split default route is installed.
            let routeInfo = try RouteExecutor.command("/sbin/route", ["-n", "get", remote])
            guard let gateway = Self.parseValue("gateway:", in: routeInfo),
                  let physicalInterface = Self.parseValue("interface:", in: routeInfo),
                  physicalInterface.hasPrefix("en") else { throw TunnelError.noPhysicalGateway }
            let interfaces = try RouteExecutor.command("/sbin/ifconfig", ["-a"])
            guard let utun = Self.findTunnel(containing: tunnelIP, in: interfaces) else {
                throw TunnelError.noTunnelInterface
            }
            let physicalRoutes = try RouteExecutor.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
            let localPrefixes = LocalIPv4Networks.parse(netstat: physicalRoutes,
                                                       physicalInterface: physicalInterface)
            guard !localPrefixes.isEmpty else { throw TunnelError.noPhysicalGateway }
            let plan = try RoutePlanner.build(serverIPv4: remote, physicalGateway: gateway,
                                              vpnInterface: utun, localPrefixes: localPrefixes,
                                              china: rules)
            let executor = RouteExecutor(journal: workdir.appendingPathComponent("routes.journal"), shouldCancel: { [weak self] in self?.cancellationRequested == true })
            // Own the executor *before* mutating routes. If installation or
            // verification fails, stop() must still find the rollback journal.
            routing = executor
            try executor.apply(plan.installOrder)
            try verifySplitRoutes(plan: plan, country: rules)
            activePlan = plan
            protectedLocalNetworks = localPrefixes
            protectedPhysicalInterface = physicalInterface
            protectedVPNInterface = utun
            state = .connected
            message = "Connected · China IPv4 split routing enabled"
            eventStore.append(.connected)
            startNetworkWatchdog()
        } catch {
            let failure = "Routing failed; VPN stopped for safety: \(error.localizedDescription)"
            stop()
            lastError = failure
            state = .failed
            message = failure
        }
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
            if let current, line.contains("inet \(ip) ") { return current }
        }
        return nil
    }
    private func verifyForeignVPNRoute(knownTunnel: String?) throws {
        let observation = try RouteExecutor.command("/sbin/route", ["-n", "get", "8.8.8.8"])
        guard let path = Self.parseValue("interface:", in: observation),
              path.hasPrefix("utun"),
              knownTunnel == nil || path == knownTunnel else {
            throw TunnelError.routeVerificationFailed
        }
    }

    private func verifySplitRoutes(plan: RoutePlan, country: RuleSet) throws {
        guard case .interface(let utun) = plan.vpnDefaults[0].destination,
              case .viaGateway(let physical) = plan.endpoint.destination,
              let direct = plan.direct.first(where: { $0.prefix.prefix < 32 })?.prefix else {
            throw TunnelError.routeVerificationFailed
        }
        let sample = IPv4CIDR.parseAddressString(direct.network + 1)
        let observation = try RouteExecutor.command("/sbin/route", ["-n", "get", sample])
        guard Self.parseValue("gateway:", in: observation) == physical,
              Self.parseValue("interface:", in: observation)?.hasPrefix("en") == true else {
            throw TunnelError.routeVerificationFailed
        }
        try verifyForeignVPNRoute(knownTunnel: utun)
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
        guard state == .connected, activeMode != .original else { return }
        do {
            if packetGuard.active { try packetGuard.verify() }
            else { try checkIPv6Bypass() }
            if activeMode == .fullVPN {
                guard let expectedTunnel = protectedVPNInterface,
                      let remote = fullVPNEndpointIPv4,
                      let expectedGateway = fullVPNGateway,
                      let expectedPhysical = protectedPhysicalInterface else {
                    throw TunnelError.routeVerificationFailed
                }
                try verifyForeignVPNRoute(knownTunnel: expectedTunnel)
                let endpoint = try RouteExecutor.command("/sbin/route", ["-n", "get", remote])
                guard Self.parseValue("interface:", in: endpoint) == expectedPhysical,
                      Self.parseValue("gateway:", in: endpoint) == expectedGateway else {
                    throw TunnelError.noPhysicalGateway
                }
                return
            }
            guard activeMode == .chinaDirect, let plan = activePlan,
                  let physicalInterface = protectedPhysicalInterface,
                  case .viaGateway(let expected) = plan.endpoint.destination else {
                throw TunnelError.routeVerificationFailed
            }
            let defaultRoute = try RouteExecutor.command("/sbin/route", ["-n", "get", "default"])
            guard Self.parseValue("gateway:", in: defaultRoute) == expected,
                  Self.parseValue("interface:", in: defaultRoute) == physicalInterface else {
                throw TunnelError.noPhysicalGateway
            }
            let localTable = try RouteExecutor.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
            let onLink = LocalIPv4Networks.parse(
                netstat: localTable, physicalInterface: physicalInterface)
            guard !onLink.isEmpty, Set(onLink) == Set(protectedLocalNetworks) else {
                throw TunnelError.noPhysicalGateway
            }
            guard let rules else { throw TunnelError.missingRules }
            try verifySplitRoutes(plan: plan, country: rules)
        } catch {
            eventStore.append(.networkChanged)
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
        guard activeMode == .chinaDirect, let oldRules = rules,
              let plan = activePlan, let executor = routing else { throw TunnelError.noActiveRoutePlan }
        let next = try RuleSet(text: text)
        guard next.routes.count >= 100 else { throw TunnelError.missingRules }
        try RuleUpdater.validateChange(previous: oldRules, next: next)
        let gateway: String
        let vpnInterface: String
        switch plan.endpoint.destination {
        case .viaGateway(let value): gateway = value
        case .interface: throw TunnelError.noPhysicalGateway
        }
        guard let interfaceRoute = plan.vpnDefaults.first,
              case .interface(let tun) = interfaceRoute.destination else {
            throw TunnelError.noTunnelInterface
        }
        vpnInterface = tun

        // Rebuild the effective routing plan, not the raw downloaded CIDR diff.
        // Otherwise a newly added CN prefix could hijack a connected local subnet.
        let updated = try RoutePlanner.build(
            serverIPv4: IPv4CIDR.parseAddressString(plan.endpoint.prefix.network),
            physicalGateway: gateway, vpnInterface: vpnInterface,
            localPrefixes: protectedLocalNetworks, china: next)
        let oldSet = Set(plan.direct)
        let nextSet = Set(updated.direct)
        let additions = nextSet.subtracting(oldSet).sorted { $0.prefix < $1.prefix }
        let removals = oldSet.subtracting(nextSet).sorted { $0.prefix < $1.prefix }

        do {
            if let current = guardPolicy {
                let policy = try LeakGuardPolicy(physical: current.physical, endpoint: current.endpoint, port: current.port,
                    transport: current.transport, local: protectedLocalNetworks, country: next.routes)
                try packetGuard.replaceRules(policy.rules(tunnel: vpnInterface), resetExistingStates: !removals.isEmpty)
                guardPolicy = policy
            }
            try executor.refreshDirectRoutes(added: additions, removed: removals)
            try verifySplitRoutes(plan: updated, country: next)
            activePlan = updated
            rules = next
            message = "Routes refreshed; OpenVPN remains connected"
        } catch {
            // A partially failed route transaction may violate the selected
            // direct/VPN policy. Disconnect rather than leave a silently
            // incorrect split route table active.
            let reason = "Route update failed, VPN disconnected for safety: \(error.localizedDescription)"
            stop()
            lastError = reason
            state = .failed
            message = reason
            throw error
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
        routing?.rollback()
        routing = nil
        activePlan = nil
        protectedLocalNetworks = []
        protectedPhysicalInterface = nil
        protectedVPNInterface = nil
        fullVPNEndpointIPv4 = nil
        fullVPNGateway = nil
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
         managementUnavailable, noPhysicalGateway, noTunnelInterface, noActiveRoutePlan, ipv6Unsafe, unresolvedRoutes, routeVerificationFailed, orphanedSession

    var errorDescription: String? {
        switch self {
        case .ipv6Unsafe: return "IPv4-only policies require no active IPv6 default route. Use Original mode or disable IPv6 before splitting. Polling is not a kill switch."
        case .engineMissing: return "Signed OpenVPN engine is not installed."
        case .needRoot: return "Approve the privileged helper in macOS."
        case .alreadyRunning: return "Another VPN session is active."
        case .missingRules: return "A valid China IPv4 rules snapshot is required."
        case .badCredential: return "Username/password is missing or invalid."
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

