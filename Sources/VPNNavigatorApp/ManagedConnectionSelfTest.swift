#if VPNNAV_LOCAL_TEST
import Foundation
import Darwin
import VPNNavigatorCore

/// Installed disposable CI only. Calls the same import, selection, connection
/// and live-switch actions as the UI, with an isolated profile library.
@MainActor
enum ManagedConnectionSelfTest {
    struct Request: Decodable {
        let profilePath: String
        let rulesPath: String
        let reportPath: String
        let mode: RoutingMode
        let customRules: [CustomRouteRule]
        let switchRoundTrip: Bool
    }
    static func run() async throws {
        guard BuildChannel.isLocal, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let index = CommandLine.arguments.firstIndex(of: "--vpnnav-local-managed-connect"),
              CommandLine.arguments.count == index + 2,
              let approval = try? LocalInstallation.load(), LocalInstallation.selfMatches([.app], approval: approval) else { throw Failure.check("approved installed app and CI arguments") }
        let request = try JSONDecoder().decode(Request.self, from: ProfileFileIO.read(URL(fileURLWithPath: CommandLine.arguments[index + 1]), maximumBytes: 64_000))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-managed-app-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let defaults = UserDefaults(suiteName: root.lastPathComponent) else { throw Failure.check("isolated preferences") }
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(backgroundServiceDefaults: defaults, profileStoreRoot: root.appendingPathComponent("Profiles"), libraryDefaults: defaults, smartDefaults: defaults)
        await model.refreshConnectionStatus()
        guard model.sessionState == .disconnected else { throw Failure.check("initial disconnected session: " + model.connectionStatus) }
        await model.importFile(URL(fileURLWithPath: request.profilePath))
        guard let profile = model.profiles.first, let result = model.importResults.first,
              case .imported(let importedID) = result.status, importedID == profile.id else { throw Failure.check("profile import: " + (model.message ?? "no result")) }
        model.clearImportReport()
        // The normal single-file import shows a success message. Acknowledge
        // that message exactly as a user does; verify the structured result.
        model.message = nil
        model.selectedID = profile.id
        model.rules = try RuleSet(text: String(decoding: ProfileFileIO.read(URL(fileURLWithPath: request.rulesPath)), as: UTF8.self))
        model.killSwitch = false
        model.requireDualStack = false
        model.reconnectOriginal = false
        model.rememberCredentials = false
        model.connectionTimeout = 180
        if let problem = await model.saveCustomRules(for: profile.id, original: [], draft: request.customRules) { throw Failure.check("save direct exceptions: " + problem) }
        await model.setMode(request.mode, for: profile.id)
        guard model.selected?.mode == request.mode, model.message == nil else { throw Failure.check("persist routing mode: " + (model.message ?? "mode mismatch")) }
        await model.connectSelected()
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while !model.connected && ProcessInfo.processInfo.systemUptime < deadline {
            await model.refreshConnectionStatus()
            if let message = model.message {
                // Inputs/certificates here are exclusively synthetic CI values.
                print("Managed application connection failed: " + message)
                throw Failure.check("connection request")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        try await verify(model, mode: request.mode)
        if request.switchRoundTrip {
            guard request.mode != .original else { throw Failure.check("live switching requires managed mode") }
            let other: RoutingMode = request.mode == .fullVPN ? .chinaDirect : .fullVPN
            await model.setMode(other, for: profile.id)
            try await verify(model, mode: other)
            await model.setMode(request.mode, for: profile.id)
            try await verify(model, mode: request.mode)
            print("PASS: real application live routing mode round trip preserves the TLS session and validated kernel routes.")
        }
        guard let report = await HelperClient.shared.sessionReport(), report.state == .connected,
              report.routingMode == request.mode, !report.requiresNetworkRecovery else { throw Failure.check("final authenticated session report") }
        try ProfileFileIO.write(JSONEncoder().encode(report), to: URL(fileURLWithPath: request.reportPath))
        print("PASS: installed application imports and directly connects in " + request.mode.rawValue + "; remains connected across the network watchdog.")
    }
    private static func verify(_ model: AppModel, mode: RoutingMode) async throws {
        // Cross at least one real watchdog tick; a transient CONNECTED receipt
        // before route/network verification is insufficient.
        try await Task.sleep(nanoseconds: 6_000_000_000)
        await model.refreshConnectionStatus()
        guard model.connected, model.activeRoutingMode == mode, !model.networkRecoveryRequired,
              !model.firewallRecoveryRequired, model.message == nil else {
            print("Managed application stability check failed: " + (model.message ?? model.connectionStatus))
            throw Failure.check("watchdog stability")
        }
    }
    enum Failure: Error, LocalizedError {
        case check(String)
        var errorDescription: String? {
            switch self { case .check(let stage): return "Managed connection fixture failed at " + stage }
        }
    }
}
#endif
