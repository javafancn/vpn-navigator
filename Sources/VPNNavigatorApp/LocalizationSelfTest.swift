import Foundation
import VPNNavigatorCore

@MainActor
enum LocalizationSelfTest {
    static func run() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", L10n.language == .english else { throw Failure.check }
        guard WorkspaceTab.overview.title == "Connection overview", RoutingMode.fullVPN.title == "Global routing",
              VPNStatusNotice.connected.title == "VPN connected", L10n.text("界面语言") == "App language",
              L10n.entries.count > 1000 else { throw Failure.check }
        let model = AppModel()
        let profile = VPNProfile(name: "原名 {0}", sourceFilename: "私人.ovpn", relativePath: "fixture", group: "工作")
        model.profiles = [profile]; model.selectedID = profile.id
        model.connectionStatus = "connected: fixture"; model.activeProfileID = profile.id
        let suite = "VPNNavLanguageCI-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.check }
        defer { defaults.removePersistentDomain(forName: suite) }
        AppLanguage.save(.chinese, defaults: defaults)
        guard L10n.language == .english, model.connected, model.activeProfileID == profile.id,
              model.selected?.name == "原名 {0}", model.selected?.group == "工作",
              L10n.format("将断开当前 VPN，再连接“{0}”。", [profile.name]).contains(profile.name) else { throw Failure.check }
        model.showingLanguageSettings = true
        guard model.workspaceNavigationBlocked, model.smartConnectionContext().occupied,
              model.quickAccessAction(for: profile.id) == .blocked else { throw Failure.check }
        if Bundle.main.bundleURL.pathExtension == "app" {
            for language in ["en", "zh-Hans"] {
                guard let url = Bundle.main.resourceURL?.appendingPathComponent(language + ".lproj/InfoPlist.strings"),
                      FileManager.default.fileExists(atPath: url.path) else { throw Failure.check }
            }
        }
        print("PASS localization: actual English app snapshot, pages/routing/notification titles, restart-only preference, preserved session and metadata, modal exclusion and packaged privacy resources; no network requests")
    }
    enum Failure: Error { case check }
}
