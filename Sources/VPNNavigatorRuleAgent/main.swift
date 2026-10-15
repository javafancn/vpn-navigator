import Foundation
import VPNNavigatorCore

/// User-scoped launchd job. Never runs as root and never edits the system routing table.
@main
enum RuleAgent {
    static func main() async {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VPNNavigator/Rules", isDirectory: true)
        let manager = RuleUpdater(folder: support)
        do {
            let candidate = try await manager.fetchCandidate()
            let current = try await manager.cached()
            if current?.routes == candidate.routes {
                print("China IPv4 rules unchanged.")
                return
            }
            // If the signed root helper has an active split-tunnel, use its typed update API.
            // Inactive/uninstalled helpers do not prevent caching for a future connection.
            let status = await HelperMessage.request { api, reply in
                api.connectionStatus(reply: reply)
            }
            if status.hasPrefix("connected:") {
                let result = await HelperMessage.request { api, reply in
                    api.updateRules(candidate.routes.map(\.description).joined(separator: "\n"), reply: reply)
                }
                guard result == "Rules applied" || result == "NO_ACTIVE_SPLIT" else {
                    fputs("Active route update failed; previous cache preserved.\n", stderr)
                    return
                }
            }
            try await manager.commit(candidate)
            print("China IPv4 rules updated: \(candidate.routes.count) prefixes.")
        } catch {
            fputs("Rule update failed, prior rules preserved: \(error.localizedDescription)\n", stderr)
        }
    }
}
private enum HelperMessage {
    static func request(_ invoke: @escaping (VPNNavigatorHelperAPI, @escaping (String) -> Void) -> Void) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
            let once = OneReply { result in
                connection.invalidate()
                continuation.resume(returning: result)
            }
            connection.remoteObjectInterface = NSXPCInterface(with: VPNNavigatorHelperAPI.self)
            connection.interruptionHandler = { once.finish("ERROR: Interrupted") }
            connection.invalidationHandler = { once.finish("ERROR: Unavailable") }
            connection.resume()
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ _ in once.finish("ERROR: Unavailable") }) as? VPNNavigatorHelperAPI else {
                once.finish("ERROR: Unavailable")
                return
            }
            invoke(remote) { once.finish($0) }
        }
    }
}
private final class OneReply: @unchecked Sendable {
    let lock = NSLock()
    var done = false
    let reply: (String) -> Void
    init(_ reply: @escaping (String) -> Void) { self.reply = reply }
    func finish(_ value: String) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { reply(value) }
    }
}
