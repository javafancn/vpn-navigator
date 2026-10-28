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
              let approval = try? LocalInstallation.load(), LocalInstallation.selfMatches([.app], approval: approval) else { throw Failure.check }
        let request = try JSONDecoder().decode(Request.self, from: ProfileFileIO.read(URL(fileURLWithPath: CommandLine.arguments[index + 1]), maximumBytes: 64_000))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-managed-app-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let defaults = UserDefaults(suiteName: root.lastPathComponent) else { throw Failure.check }
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        let model = AppModel(backgroundServiceDefaults: defaults, profileStoreRoot: root.appendingPathComponent("Profiles"), libraryDefaults: defaults, smartDefaults: defaults)
        await model.refreshConnectionStatus()
        guard model.sessionState == .disconnected else { throw Failure.check }
        await model.importFile(URL(fileURLWithPath: request.profilePath))
        model.clearImportReport()
        guard let profile = model.profiles.first, model.message == nil else { throw Failure.check }
        model.selectedID = profile.id
        model.rules = try RuleSet(text: String(decoding: ProfileFileIO.read(URL(fileURLWithPath: request.rulesPath)), as: UTF8.self))
        model.killSwitch = false
        model.requireDualStack = false
        model.reconnectOriginal = false
        model.rememberCredentials = false
        model.connectionTimeout = 180
        guard await model.saveCustomRules(for: profile.id, original: [], draft: request.customRules) == nil else { throw Failure.check }
        await model.setMode(request.mode, for: profile.id)
        guard model.selected?.mode == request.mode, model.message == nil else { throw Failure.check }
        await model.connectSelected()
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while !model.connected && ProcessInfo.processInfo.systemUptime < deadline {
            await model.refreshConnectionStatus()
            if let message = model.message {
                // Inputs/certificates here are exclusively synthetic CI values.
                print("Managed application connection failed: " + message)
                throw Failure.check
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        try await verify(model, mode: request.mode)
        if request.switchRoundTrip {
            guard request.mode != .original else { throw Failure.check }
            let other: RoutingMode = request.mode == .fullVPN ? .chinaDirect : .fullVPN
            await model.setMode(other, for: profile.id)
            try await verify(model, mode: other)
            await model.setMode(request.mode, for: profile.id)
            try await verify(model, mode: request.mode)
            print("PASS: real application live routing mode round trip preserves the TLS session and validated kernel routes.")
        }
        guard let report = await HelperClient.shared.sessionReport(), report.state == .connected,
              report.routingMode == request.mode, !report.requiresNetworkRecovery else { throw Failure.check }
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
            throw Failure.check
        }
    }
    enum Failure: Error { case check }
}
#endif
