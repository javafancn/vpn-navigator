import Foundation
import ServiceManagement
import VPNNavigatorCore

/// User-scoped launchd job. Never runs as root and never edits the system routing table.
@main
enum RuleAgent {
    static func main() async {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VPNNavigator/Rules", isDirectory: true)
        let manager = RuleUpdater(folder: support)
        let manager6 = APNICIPv6PreviewStore(root: support)
        do {
            async let feed4 = manager.fetchCandidate()
            async let feed6 = manager6.fetchCandidate()
            let (candidate, candidate6) = try await (feed4, feed6)
            let current = try await manager.cached()
            let current6 = try await manager6.cached()
            if current?.routes == candidate.routes, current6?.routes == candidate6.routes {
                print("China IPv4/IPv6 rules unchanged.")
                return
            }
            // If the signed root helper has an active split-tunnel, use its typed update API.
            // Inactive/uninstalled helpers do not prevent caching for a future connection.
            let enabled = BuildChannel.isLocal ? FileManager.default.fileExists(atPath: LocalInstallation.manifest.path) : SMAppService.daemon(plistName: HelperIdentity.plistName).status == .enabled
            let status: String
            if enabled {
                status = await HelperMessage.request { api, reply in api.connectionStatus(reply: reply) }
                guard status.hasPrefix("connected:") || status.hasPrefix("disconnected:") else {
                    fputs("Helper state is changing or unresolved; preserve the current cache.\n", stderr)
                    return
                }
            } else { status = "disconnected: helper not enabled" }
            if status.hasPrefix("connected:") {
                let result = await HelperMessage.request { api, reply in
                    api.updateRules(RoutingRuleBundle(ipv4: candidate.routes.map(\.description).joined(separator: "\n"), ipv6: candidate6.routes.map(\.description).joined(separator: "\n")).json, reply: reply)
                }
                guard result == "Rules applied" || result == "NO_ACTIVE_SPLIT" else {
                    fputs("Active route update failed; previous cache preserved.\n", stderr)
                    return
                }
            }
            try await manager.commit(candidate)
            try await manager6.commit(candidate6)
            print("China IPv4/IPv6 rules updated: \(candidate.routes.count) prefixes.")
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
            guard let requirement = PrivilegedServiceTrust.helperRequirement() else {
                once.finish("ERROR: Background rule agent is not signed")
                return
            }
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: VPNNavigatorHelperAPI.self)
            connection.interruptionHandler = { once.finish("ERROR: Interrupted") }
            connection.invalidationHandler = { once.finish("ERROR: Unavailable") }
            connection.resume()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600) {
                once.finish("ERROR: Timed out waiting for helper route transaction")
            }
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

