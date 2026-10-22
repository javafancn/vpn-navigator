import Foundation
import VPNNavigatorCore

@MainActor
enum SmartConnectionSelfTest {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let suite = "VPNNavSmartCI-" + UUID().uuidString
        guard let isolated = UserDefaults(suiteName: suite) else { throw Failure.check }
        defer { isolated.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(backgroundServiceDefaults: isolated, profileStoreRoot: root,
                             libraryDefaults: isolated, smartDefaults: isolated)
        defer { model.smartConnection.stop(); model.quickAccess.shutdown() }
        let source = root.appendingPathComponent("fixture.ovpn")
        try "client\ndev tun\nremote fixture.example 1194\n<ca>\nFAKE\n</ca>\n".write(to: source, atomically: true, encoding: .utf8)
        await model.importFile(source); model.clearImportReport()
        guard let profile = model.selected else { throw Failure.check }
        let smart = model.smartConnection
        guard !smart.preferences.enabled, !smart.preferences.notifications,
              smart.target(automatic: true) == nil, smart.target(automatic: false)?.id == profile.id else { throw Failure.check }
        let connected = SessionReport(state: .connected, message: "sensitive-host", activeProfileID: profile.id,
            receivedBytes: nil, sentBytes: nil, attemptID: UUID(), networkRecoveryRequired: false,
            routingMode: .fullVPN, routingRevision: UUID())
        smart.observe(connected)
        guard smart.target(automatic: true)?.id == profile.id else { throw Failure.check }
        smart.update { $0.enabled = true; $0.onLaunch = true; $0.onNetworkRestore = true; $0.profileID = profile.id }
        let before = model.connectionStatus
        smart.schedule(.launch); smart.pauseForManualDisconnect()
        try await Task.sleep(nanoseconds: 2_700_000_000)
        guard smart.preferences.paused, model.connectionStatus == before,
              SmartConnectionStore(defaults: isolated).load().paused else { throw Failure.check }
        smart.togglePause()
        model.showingAccountCredentials = true
        guard model.smartConnectionContext().occupied else { throw Failure.check }
        await model.connectSelected(automatically: true, automationPermit: { true })
        guard model.connectionStatus == before else { throw Failure.check }
        model.showingAccountCredentials = false
        await model.connectSelected(automatically: true, automationPermit: { false })
        guard model.connectionStatus == before else { throw Failure.check }
        model.applyVerifiedSessionReport(connected)
        guard model.smartConnectionContext().activeProfileID == profile.id, model.menuStatusTitle == "已连接" else { throw Failure.check }
        let failed = SessionReport(state: .failed, message: "sensitive-host", activeProfileID: profile.id,
            receivedBytes: nil, sentBytes: nil, attemptID: connected.attemptID,
            networkRecoveryRequired: true, failureCode: .authentication)
        model.applyVerifiedSessionReport(failed)
        guard smart.preferences.paused, model.menuStatusTitle == "连接异常，请检查",
              !smart.preferences.notifications, smart.notificationStatus == "状态通知未开启" else { throw Failure.check }
        // Does not initialize UserNotifications or request any OS permission.
        await smart.deliver(.test)
        print("PASS smart connection: isolated opt-in, confirmed history, cancellation, manual pause persistence, credential/permit gates, active-session ownership, failure pause, notification opt-out")
    }
    enum Failure: Error { case check }
}
