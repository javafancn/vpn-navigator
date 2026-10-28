import Foundation
import ServiceManagement
import Darwin
import VPNNavigatorCore

/// This client never executes privileged commands. A trusted, separately signed
/// launch daemon enforces code-signing identity and validates all inputs again.
final class HelperClient {
    static let shared = HelperClient()
    private init() {}
    private let activity = HelperActivityGate()

    func resumeAfterCancelledQuit() { activity.resume() }

    /// Drain existing requests and block new polls before asking the helper
    /// to exit. Observe PID disappearance without sending another XPC request.
    func stopForApplicationQuit() async throws {
        activity.pause()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while activity.count > 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw LocalInstallError.command }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let result = await ask(duringQuit: true) { $0.stopWhenIdle(reply: $1) }
        guard let receipt = HelperQuitReceipt.decode(result) else { throw LocalInstallError.command }
        for _ in 0..<50 {
            // This is a read-only existence check. A root-owned process yields
            // EPERM while alive; only ESRCH confirms it has actually exited.
            if kill(receipt.processID, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LocalInstallError.command
    }

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
        catch { return L10n.text("安装事务记录无法核验，请保留现状并进行人工诊断。不要删除网络恢复记录。") }
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

    private func ask(timeout: TimeInterval = 12, duringQuit: Bool = false, _ call: @escaping (VPNNavigatorHelperAPI, @escaping (String) -> Void) -> Void) async -> String {
        guard activity.enter(duringQuit: duringQuit) else { return "ERROR: Application is quitting" }
        defer { activity.leave() }
        return await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperIdentity.machService,
                                           options: .privileged)
            let completion = OnceReply { value in
                connection.invalidate()
                continuation.resume(returning: value)
            }
            // Validate the *server* identity as well as the server's incoming
            // client requirement. Never send VPN credentials to a fake daemon.
            guard let requirement = PrivilegedServiceTrust.helperRequirement() else {
                completion.finish(L10n.text("ERROR: 当前程序身份或安装批准未通过检查，请安装或修复对应通道的安装包"))
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
    func disconnectSession(_ expected: QuickAccessSession) async -> String {
        await ask(timeout: 30) { helper, reply in
            helper.disconnectSession(expectedProfileID: expected.profileID.uuidString,
                expectedAttemptID: expected.attemptID.uuidString, reply: reply)
        }
    }
    func recoverOrphanedRoutes() async -> String {
        await ask(timeout: 60) { helper, reply in helper.recoverOrphanedRoutes(reply: reply) }
    }
    func lookupRoute(_ request: RouteLookupRequest) async throws -> RouteLookupResult {
        let raw = await ask(timeout: 15) { helper, reply in helper.explainRoute(request.json, reply: reply) }
        guard raw.utf8.count <= 16_000, let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(RouteLookupResult.self, from: data),
              result.request == request, result.decision.ip == request.ip,
              result.observedInterface.utf8.count <= 64, result.observedGateway.utf8.count <= 128 else { throw ProbeError.commandFailed }
        return result
    }
    func updateRules(_ rules: String) async -> String {
        await ask(timeout: 600) { helper, reply in helper.updateRules(rules, reply: reply) }
    }
    func switchRoutingMode(_ request: RoutingModeSwitchRequest, rules: String) async -> String {
        await ask(timeout: 600) { helper, reply in
            helper.switchRoutingMode(mode: request.target.rawValue, rules: rules,
                expectedProfileID: request.profileID.uuidString, expectedAttemptID: request.attemptID.uuidString,
                expectedMode: request.previous.rawValue, expectedRevision: request.revision.uuidString, reply: reply)
        }
    }
}

private final class HelperActivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var active = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return active }
    func pause() { lock.lock(); paused = true; lock.unlock() }
    func resume() { lock.lock(); paused = false; lock.unlock() }
    func enter(duringQuit: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !paused || duringQuit else { return false }
        active += 1; return true
    }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
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

