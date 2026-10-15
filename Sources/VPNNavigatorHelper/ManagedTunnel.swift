import Foundation
import Darwin
import VPNNavigatorCore

/// Root-owned, single-session OpenVPN process. The caller has already passed code-signing verification.
final class ManagedTunnel {
    let queue = DispatchQueue(label: "VPNNavigator.ManagedTunnel")
    private var networkWatchdog: DispatchSourceTimer?
    private let workdir = URL(fileURLWithPath: "/var/run/vpn-navigator", isDirectory: true)
    private var process: Process?
    private var management: ManagementSocket?
    private var routing: RouteExecutor?
    private var activeMode: RoutingMode = .original
    private var rules: RuleSet?
    private var activePlan: RoutePlan?
    private var lastError: String?

    init() {
        // Reconcile a previous helper crash before allowing a new VPN session.
        let leftover = workdir.appendingPathComponent("routes.journal")
        if FileManager.default.fileExists(atPath: leftover.path) {
            _ = RouteExecutor(journal: leftover)
        }
    }
    private(set) var state: TunnelState = .disconnected
    private(set) var message = "Disconnected"
    var activeSplitRoutes: Bool { activeMode == .chinaDirect && routing != nil }

    func start(profile text: String, mode: RoutingMode, ruleText: String,
               username: String, password: String) throws {
        guard getuid() == 0 else { throw TunnelError.needRoot }
        guard process == nil else { throw TunnelError.alreadyRunning }
        let validated = try ProfileSafety.validate(text)
        // IPv4-only routing cannot protect IPv6. Refuse a non-original split or
        // full-VPN mode while native IPv6 has a non-tunnel path (fail closed).
        if mode != .original { try checkIPv6Bypass() }
        if mode == .chinaDirect {
            rules = try RuleSet(text: ruleText)
            guard let rules, rules.routes.count >= 100 else { throw TunnelError.missingRules }
        }
        guard !username.contains("\n"), !password.contains("\n"),
              username.utf8.count < 1024, password.utf8.count < 4096 else { throw TunnelError.badCredential }
        if validated.requestsCredentials && (username.isEmpty || password.isEmpty) {
            throw TunnelError.badCredential
        }
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workdir.path)
        let configFile = workdir.appendingPathComponent("active.ovpn")
        try validated.text.write(to: configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        var options = ["--config", configFile.path]
        if mode == .chinaDirect { options += ["--route-noexec"] }
        if mode == .fullVPN { options += ["--redirect-gateway", "def1"] }
        let managementPath = workdir.appendingPathComponent("management.sock").path
        try? FileManager.default.removeItem(atPath: managementPath)
        options += ["--management", managementPath, "unix", "--management-hold", "--management-up-down", "--management-query-passwords"]

        // OpenVPN must be provided by a separately vetted signed distribution.
        // NEVER launch an arbitrary executable from an imported .ovpn or client-supplied path.
        let binary = try ExecutableTrust.trustedOpenVPN().path
        // The OpenVPN 2.7 platform DNS hook must ship with the standalone
        // binary; otherwise a successful tunnel may silently retain wrong DNS.
        let dnsHook = try ExecutableTrust.trustedDNSUpDown()
        options += ["--script-security", "2", "--dns-updown", dnsHook.path]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = options
        task.currentDirectoryURL = workdir
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.stopRoutesAndReset() }
        }
        activeMode = mode
        lastError = nil
        process = task
        state = .connecting
        message = "OpenVPN is starting"
        do {
            try task.run()
            let socket = ManagementSocket()
            if validated.requestsCredentials {
                socket.setCredentials(username: username, password: password)
            }
            socket.onUnsupportedChallenge = { [weak self] in
                self?.queue.async {
                    self?.stop()
                    self?.lastError = "OpenVPN requested an unsupported authentication method."
                    self?.state = .failed
                    self?.message = self?.lastError ?? "Authentication failed"
                }
            }
            socket.onExit = { [weak self] in
                self?.queue.async { if self?.process != nil { self?.stop() } }
            }
            socket.onState = { [weak self] snapshot in
                self?.queue.async { self?.handle(snapshot) }
            }
            management = socket
            // OpenVPN creates the socket asynchronously. Bounded retry only.
            var success = false
            for _ in 0..<50 {
                if (try? socket.open(path: managementPath)) != nil { success = true; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard success else { throw TunnelError.managementUnavailable }
        } catch {
            stop()
            throw error
        }
    }
    private func checkIPv6Bypass() throws {
        let output = try? RouteExecutor.command("/sbin/route",
            ["-n", "get", "-inet6", "2606:4700:4700::1111"])
        if let output, output.components(separatedBy: .newlines).contains(where: {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("interface:") && !line.contains("utun")
        }) {
            throw TunnelError.ipv6Unsafe
        }
    }
    private func handle(_ snapshot: TunnelSnapshot) {
        state = snapshot.state
        message = snapshot.message
        if snapshot.state == .connected && activeMode == .chinaDirect {
            state = .connecting
            message = "Applying and validating China IPv4 routes"
        }
        if snapshot.state == .reconnecting {
            networkWatchdog?.cancel()
            networkWatchdog = nil
            routing?.rollback()
            routing = nil
            activePlan = nil
        }
        guard snapshot.state == .connected, activeMode == .chinaDirect,
              routing == nil, let remote = snapshot.remoteIPv4, let tunnelIP = snapshot.localTunnelIPv4,
              let rules else { return }
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
            let plan = try RoutePlanner.build(serverIPv4: remote, physicalGateway: gateway,
                                              vpnInterface: utun, localPrefixes: [], china: rules)
            let executor = RouteExecutor(journal: workdir.appendingPathComponent("routes.journal"))
            try executor.apply(plan.installOrder)
            activePlan = plan
            routing = executor
            state = .connected
            message = "Connected · China IPv4 split routing enabled"
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
    private func startNetworkWatchdog() {
        networkWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: .seconds(15))
        timer.setEventHandler { [weak self] in self?.verifyPhysicalNetwork() }
        networkWatchdog = timer
        timer.resume()
    }

    private func verifyPhysicalNetwork() {
        guard state == .connected, activeMode == .chinaDirect,
              let plan = activePlan else { return }
        guard case .viaGateway(let expected) = plan.endpoint.destination else { return }
        do {
            let route = try RouteExecutor.command("/sbin/route", ["-n", "get", "default"])
            guard Self.parseValue("gateway:", in: route) == expected,
                  Self.parseValue("interface:", in: route)?.hasPrefix("en") == true else {
                throw TunnelError.noPhysicalGateway
            }
            try checkIPv6Bypass()
        } catch {
            let failure = "Physical network changed or IPv6 became unsafe; VPN disconnected: \(error.localizedDescription)"
            stop()
            lastError = failure
            state = .failed
            message = failure
        }
    }

    func changeRules(_ text: String) throws {
        guard activeMode == .chinaDirect, let oldRules = rules,
              let plan = activePlan, let executor = routing else { throw TunnelError.noActiveRoutePlan }
        let next = try RuleSet(text: text)
        guard next.routes.count >= 100 else { throw TunnelError.missingRules }
        try RuleUpdater.validateChange(previous: oldRules, next: next)
        let diff = next.diff(from: oldRules)
        let gateway: String
        switch plan.endpoint.destination {
        case .viaGateway(let value): gateway = value
        case .interface: throw TunnelError.noPhysicalGateway
        }
        try executor.refreshDirectRoutes(
            added: diff.added.map { RouteTarget($0, .viaGateway(gateway)) },
            removed: diff.removed.map { RouteTarget($0, .viaGateway(gateway)) }
        )
        rules = next
        message = "Routes refreshed; OpenVPN remains connected"
    }
    func stop() {
        networkWatchdog?.cancel()
        networkWatchdog = nil
        lastError = nil
        // Roll back routes before terminating the tunnel.
        routing?.rollback()
        routing = nil
        activePlan = nil
        management?.close()
        management = nil
        if let task = process, task.isRunning { task.terminate() }
        stopRoutesAndReset()
    }
    private func stopRoutesAndReset() {
        routing?.rollback()
        routing = nil
        activePlan = nil
        process = nil
        state = lastError == nil ? .disconnected : .failed
        message = lastError ?? "Disconnected"
        for name in ["active.ovpn", "management.sock", "auth.txt"] {
            try? FileManager.default.removeItem(at: workdir.appendingPathComponent(name))
        }
    }
}
enum TunnelError: Error, LocalizedError {
    case needRoot, alreadyRunning, missingRules, badCredential, engineMissing,
         managementUnavailable, noPhysicalGateway, noTunnelInterface, noActiveRoutePlan, ipv6Unsafe

    var errorDescription: String? {
        switch self {
        case .ipv6Unsafe: return "IPv6 has a physical-network route; IPv4-only split routing would leak traffic. Use Original mode or disable IPv6 before enabling IPv4 splitting."
        case .engineMissing: return "Signed OpenVPN engine is not installed."
        case .needRoot: return "Approve the privileged helper in macOS."
        case .alreadyRunning: return "Another VPN session is active."
        case .missingRules: return "A valid China IPv4 rules snapshot is required."
        case .badCredential: return "Username/password is missing or invalid."
        case .managementUnavailable: return "OpenVPN management socket is unavailable."
        case .noPhysicalGateway: return "Cannot identify the local physical gateway."
        case .noTunnelInterface: return "Cannot verify the OpenVPN utun interface."
        case .noActiveRoutePlan: return "No active split-routing session."
        }
    }
}
