import Foundation
import Darwin
import VPNNavigatorCore

/// Root-owned, single-session OpenVPN process. The caller has already passed code-signing verification.
final class ManagedTunnel {
    private let queue = DispatchQueue(label: "VPNNavigator.ManagedTunnel")
    private let workdir = URL(fileURLWithPath: "/var/run/vpn-navigator", isDirectory: true)
    private var process: Process?
    private var management: ManagementSocket?
    private var routing: RouteExecutor?
    private var activeMode: RoutingMode = .original
    private var rules: RuleSet?
    private var activePlan: RoutePlan?
    private(set) var state: TunnelState = .disconnected
    private(set) var message = "Disconnected"

    func start(profile text: String, mode: RoutingMode, ruleText: String,
               username: String, password: String) throws {
        guard getuid() == 0 else { throw TunnelError.needRoot }
        guard process == nil else { throw TunnelError.alreadyRunning }
        let validated = try ProfileSafety.validate(text)
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
        let credentialsFile = workdir.appendingPathComponent("auth.txt")
        if validated.requestsCredentials {
            try (username + "\n" + password + "\n").write(to: credentialsFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFile.path)
            // --auth-user-pass on CLI overrides the profile's bare auth-user-pass.
            options += ["--auth-user-pass", credentialsFile.path]
        }
        let managementPath = workdir.appendingPathComponent("management.sock").path
        try? FileManager.default.removeItem(atPath: managementPath)
        options += ["--management", managementPath, "unix", "--management-hold", "--management-up-down"]

        // OpenVPN must be provided by a separately vetted signed distribution.
        // NEVER launch an arbitrary executable from an imported .ovpn or client-supplied path.
        let binary = "/usr/local/libexec/vpn-navigator/openvpn"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw TunnelError.engineMissing }
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
        process = task
        state = .connecting
        message = "OpenVPN is starting"
        do {
            try task.run()
            let socket = ManagementSocket()
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
    private func handle(_ snapshot: TunnelSnapshot) {
        state = snapshot.state
        message = snapshot.message
        guard snapshot.state == .connected, activeMode == .chinaDirect,
              routing == nil, let remote = snapshot.remoteIPv4, let tunnelIP = snapshot.localTunnelIPv4,
              let rules else { return }
        do {
            // Physical gateway is determined BEFORE a split default route is installed.
            let routeInfo = try RouteExecutor.command("/sbin/route", ["-n", "get", remote])
            guard let gateway = parseValue("gateway:", in: routeInfo),
                  let physicalInterface = parseValue("interface:", in: routeInfo),
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
            message = "Connected · China IPv4 split routing enabled"
        } catch {
            message = "Routing failed; VPN stopped for safety"
            state = .failed
            stop()
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
    func changeRules(_ text: String) throws {
        guard activeMode == .chinaDirect, let oldRules = rules,
              let plan = activePlan, let executor = routing else { throw TunnelError.noActiveRoutePlan }
        let next = try RuleSet(text: text)
        guard next.routes.count >= 100 else { throw TunnelError.missingRules }
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
        state = .disconnected
        message = "Disconnected"
        for name in ["active.ovpn", "auth.txt", "management.sock"] {
            try? FileManager.default.removeItem(at: workdir.appendingPathComponent(name))
        }
    }
}
enum TunnelError: Error {
    case needRoot, alreadyRunning, missingRules, badCredential, engineMissing,
         managementUnavailable, noPhysicalGateway, noTunnelInterface, noActiveRoutePlan
}
