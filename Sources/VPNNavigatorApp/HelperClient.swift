import Foundation
import ServiceManagement
import VPNNavigatorCore

/// This client never executes privileged commands. A trusted, separately signed
/// launch daemon enforces code-signing identity and validates all inputs again.
final class HelperClient {
    static let shared = HelperClient()
    private init() {}

    var installationStatus: SMAppService.Status {
        SMAppService.daemon(plistName: HelperIdentity.plistName).status
    }

    func requestRegistration() throws {
        try SMAppService.daemon(plistName: HelperIdentity.plistName).register()
    }
    func unregister() throws {
        try SMAppService.daemon(plistName: HelperIdentity.plistName).unregister()
    }

    private func ask(timeout: TimeInterval = 12, _ call: @escaping (VPNNavigatorHelperAPI, @escaping (String) -> Void) -> Void) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperIdentity.machService,
                                           options: .privileged)
            let completion = OnceReply { value in
                connection.invalidate()
                continuation.resume(returning: value)
            }
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
    func status() async -> String {
        await ask { helper, reply in helper.connectionStatus(reply: reply) }
    }
    func connect(profile: String, mode: RoutingMode, rules: String,
                 username: String, password: String) async -> String {
        await ask { helper, reply in
            helper.connect(profile: profile, mode: mode.rawValue, rules: rules,
                           username: username, password: password, reply: reply)
        }
    }
    func disconnect() async -> String {
        await ask(timeout: 30) { helper, reply in helper.disconnect(reply: reply) }
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
