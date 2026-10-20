import Foundation
import ServiceManagement
import VPNNavigatorCore

/// This client never executes privileged commands. A trusted, separately signed
/// launch daemon enforces code-signing identity and validates all inputs again.
final class HelperClient {
    static let shared = HelperClient()
    private init() {}

    var installationStatus: SMAppService.Status {
        if BuildChannel.isLocal {
            if LocalInstallation.isInstallationPending { return .requiresApproval }
            if FileManager.default.fileExists(atPath: LocalInstallation.manifest.path) {
                guard let value = try? LocalInstallation.load(), value.ownerUID == getuid() else { return .requiresApproval }
                return .enabled
            }
            return FileManager.default.fileExists(atPath: LocalInstallation.retired.path) ? .notRegistered : .notFound
        }
        return SMAppService.daemon(plistName: HelperIdentity.plistName).status
    }
    var localInstallationIssue: String? {
        guard BuildChannel.isLocal, LocalInstallation.isInstallationPending else { return nil }
        do { return try LocalInstallation.pendingTransaction()?.summary }
        catch { return "安装事务记录无法核验，请保留现状并进行人工诊断。不要删除网络恢复记录。" }
    }

    func requestRegistration() throws {
        guard !BuildChannel.isLocal else { throw LocalInstallError.notInstalled }
        try SMAppService.daemon(plistName: HelperIdentity.plistName).register()
    }
    func unregister() async throws {
        if BuildChannel.isLocal {
            let result = await ask { api, reply in api.prepareLocalMaintenance(reply: reply) }
            guard result == "Local services disabled" else { throw LocalInstallError.recoveryRequired }
            for _ in 0..<30 {
                if (try? UserServices.launchctl(["print", "system/" + LocalInstallation.daemonLabel])) == nil { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw LocalInstallError.command
        }
        try await SMAppService.daemon(plistName: HelperIdentity.plistName).unregister()
    }

    private func ask(timeout: TimeInterval = 12, _ call: @escaping (VPNNavigatorHelperAPI, @escaping (String) -> Void) -> Void) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperIdentity.machService,
                                           options: .privileged)
            let completion = OnceReply { value in
                connection.invalidate()
                continuation.resume(returning: value)
            }
            // Validate the *server* identity as well as the server's incoming
            // client requirement. Never send VPN credentials to a fake daemon.
            guard let requirement = PrivilegedServiceTrust.helperRequirement() else {
                completion.finish("ERROR: 当前程序身份或安装批准未通过检查，请安装或修复对应通道的安装包")
                return
            }
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: VPNNavigatorHelperAPI.self)
            connection.interruptionHandler = { completion.finish("ERROR: Helper interrupted") }
            connection.invalidationHandler = { completion.finish("ERROR: Helper unavailable or not authorized") }
            connection.resume()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                completion.finish("ERROR: Privileged helper did not respond before the operation deadline")
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                completion.finish("ERROR: \(error.localizedDescription)")
            }) as? VPNNavigatorHelperAPI else {
                completion.finish("ERROR: Invalid privileged service interface")
                return
            }
            call(proxy) { completion.finish($0) }
        }
    }
    func ping() async -> String {
        await ask { helper, reply in helper.health(reply: reply) }
    }
    func sessionReport() async -> SessionReport? {
        let raw = await ask { helper, reply in helper.sessionSnapshot(reply: reply) }
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionReport.self, from: data)
    }
    func activeProfile() async -> UUID? {
        UUID(uuidString: await ask { helper, reply in helper.activeProfile(reply: reply) })
    }
    func status() async -> String {
        await ask { helper, reply in helper.connectionStatus(reply: reply) }
    }
    func connect(profile: String, profileID: UUID, mode: RoutingMode, rules: String,
                 username: String, password: String, preferences: SessionPreferences, attemptID: UUID) async -> String {
        await ask { helper, reply in
            helper.connect(profile: profile, profileID: profileID.uuidString,
                           mode: mode.rawValue, rules: rules,
                           username: username, password: password, preferences: preferences.json, attemptID: attemptID.uuidString, reply: reply)
        }
    }
    func submitChallenge(id: UUID, response: String) async -> String {
        await ask { helper, reply in helper.submitChallenge(id: id.uuidString, response: response, reply: reply) }
    }
    func diagnosticEvents() async -> [DiagnosticEvent] {
        let raw = await ask { helper, reply in helper.diagnosticEvents(reply: reply) }
        guard raw.utf8.count < 200_000, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([DiagnosticEvent].self, from: data)) ?? []
    }
    func disconnect(attemptID: UUID? = nil) async -> String {
        await ask(timeout: 30) { helper, reply in helper.disconnect(cancelAttemptID: attemptID?.uuidString ?? "", reply: reply) }
    }
    func trafficStatus() async -> String {
        await ask { helper, reply in helper.trafficStatus(reply: reply) }
    }
    func recoverOrphanedRoutes() async -> String {
        await ask(timeout: 60) { helper, reply in helper.recoverOrphanedRoutes(reply: reply) }
    }
    func updateRules(_ rules: String) async -> String {
        await ask(timeout: 600) { helper, reply in helper.updateRules(rules, reply: reply) }
    }
}

/// NSXPC errors and callbacks can arrive concurrently. Resume continuations exactly once.
private final class OnceReply: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let done: (String) -> Void
    init(_ done: @escaping (String) -> Void) { self.done = done }
    func finish(_ result: String) {
        lock.lock()
        let shouldFire = !finished
        finished = true
        lock.unlock()
        if shouldFire { done(result) }
    }
}

