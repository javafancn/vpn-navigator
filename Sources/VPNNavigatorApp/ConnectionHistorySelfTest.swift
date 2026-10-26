import Foundation
import VPNNavigatorCore

@MainActor
enum ConnectionHistorySelfTest {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let suite = "VPNNavHistoryCI-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.check }
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(backgroundServiceDefaults: defaults, profileStoreRoot: root.appendingPathComponent("profiles"), libraryDefaults: defaults, smartDefaults: defaults)
        defer { model.profileHealth.stop(); model.smartConnection.stop(); model.quickAccess.shutdown() }
        let file = root.appendingPathComponent("fixture.ovpn")
        try "client\ndev tun\nremote fixture.example\n<ca>\nSYNTHETIC_CA\n</ca>\n".write(to: file, atomically: true, encoding: .utf8)
        await model.importFile(file); model.clearImportReport()
        guard let profile = model.selected else { throw Failure.check }
        let history = model.connectionHistory; await history.start()
        model.showingConnectionHistory = true
        guard model.smartConnectionContext().occupied, model.quickAccessAction(for: profile.id) == .blocked else { throw Failure.check }
        let attempt = UUID(), now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        func report(_ received: UInt64, attempt: UUID) -> SessionReport {
            .init(state: .connected, message: "DO_NOT_PERSIST_THIS_SECRET.example", activeProfileID: profile.id, receivedBytes: received, sentBytes: received / 10,
                attemptID: attempt, networkRecoveryRequired: false, routingMode: .original)
        }
        history.observe(.begin(profileID: profile.id, attemptID: attempt), at: now.addingTimeInterval(-9), uptime: uptime - 9)
        history.observe(.report(.init(report(1000, attempt: attempt))), at: now.addingTimeInterval(-8), uptime: uptime - 8)
        history.observe(.report(.init(report(4000, attempt: attempt))), at: now.addingTimeInterval(-5), uptime: uptime - 5)
        await history.waitForPending()
        guard history.state.records.count == 1, history.state.quality.receivedPerSecond == 1000,
              history.state.quality.observedConnectedSeconds == 3 else { throw Failure.check }
        model.applyVerifiedSessionReport(report(4000, attempt: attempt)); await history.waitForPending()
        let identity = model.activeProfileID
        await history.clearAndPause()
        guard history.state.records.isEmpty, !history.state.preferences.enabled, model.connected, model.activeProfileID == identity else { throw Failure.check }
        model.applyVerifiedSessionReport(report(5000, attempt: attempt)); await history.waitForPending()
        guard history.state.records.isEmpty else { throw Failure.check }
        await history.configure(.init(enabled: true, retentionDays: 90))
        guard history.state.preferences.retentionDays == 90, history.state.records.count == 1, model.connected else { throw Failure.check }
        model.applyVerifiedSessionReport(.init(state: .disconnected, message: "synthetic", activeProfileID: nil,
            receivedBytes: nil, sentBytes: nil, attemptID: attempt, networkRecoveryRequired: false))
        await history.waitForPending()
        guard history.state.records.first?.outcome == .completed else { throw Failure.check }
        let json = try String(contentsOf: root.appendingPathComponent("ConnectionHistory/history.json"))
        guard !json.contains("DO_NOT_PERSIST"), !json.contains("fixture.example"), !json.contains("SYNTHETIC_CA") else { throw Failure.check }
        guard ConnectionHistoryDisplay.rate(nil) == "等待采样", ConnectionHistoryDisplay.duration(3661) == "1:01:01",
              !ConnectionHistoryDisplay.rate(Double.greatestFiniteMagnitude).isEmpty, !ConnectionHistoryDisplay.bytes(.max).isEmpty else { throw Failure.check }
        print("PASS connection history: ordered native observation, real-interval rate formatting, modal smart/quick exclusion, clear-and-pause persistence, retention, secret exclusion and unchanged VPN state; no VPN or permission requests")
    }
    enum Failure: Error { case check }
}
