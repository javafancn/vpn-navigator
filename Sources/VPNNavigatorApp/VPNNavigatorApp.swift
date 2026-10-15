import SwiftUI
import VPNNavigatorCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var selectedID: UUID? {
        didSet {
            if oldValue != selectedID {
                username = ""
                password = ""
            }
        }
    }
    @Published var rules: RuleSet?
    @Published var ruleSnapshots: [RuleSnapshot] = []
    @Published var busy = false
    @Published var message: String?
    @Published var helperStatus = "Unavailable"
    @Published var availableInstaller: URL?
    @Published var availableReleasePage: URL?
    @Published var connectionStatus = "disconnected: Not connected"
    @Published var username = ""
    @Published var password = ""
    @Published var rememberCredentials = UserDefaults.standard.bool(forKey: "rememberCredentials") {
        didSet {
            UserDefaults.standard.set(rememberCredentials, forKey: "rememberCredentials")
            if !rememberCredentials, let selectedID { KeychainVault.remove(id: selectedID) }
        }
    }

    private let store: ProfileStore
    private let updater: RuleUpdater
    private let helper = HelperClient.shared

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VPNNavigator", isDirectory: true)
        store = ProfileStore(root: root.appendingPathComponent("Profiles"))
        updater = RuleUpdater(folder: root.appendingPathComponent("Rules"))
        Task { await load() }
        Task {
            while !Task.isCancelled {
                await refreshConnectionStatus()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    var selected: VPNProfile? { profiles.first { $0.id == selectedID } }
    var connected: Bool { connectionStatus.hasPrefix("connected:") }
    var connecting: Bool { connectionStatus.hasPrefix("connecting:") || connectionStatus.hasPrefix("authenticating:") }

    func load() async {
        do {
            profiles = try await store.list()
            if selectedID == nil { selectedID = profiles.first?.id }
            rules = try await updater.cached()
            ruleSnapshots = try await updater.snapshots()
        } catch { message = error.localizedDescription }
    }
    func importFile(_ url: URL) async {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let item = try await store.importProfile(from: url)
            await load()
            selectedID = item.id
        } catch { message = "Import failed: \(error.localizedDescription)" }
    }
    func setMode(_ mode: RoutingMode) async {
        guard var item = selected else { return }
        item.mode = mode
        do { try await store.update(item); await load() }
        catch { message = error.localizedDescription }
    }
    func updateMetadata(name: String, group: String, notes: String, favorite: Bool) async {
        guard var item = selected else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 100,
              !cleanGroup.isEmpty, cleanGroup.count <= 48, notes.count <= 4000 else {
            message = "Profile name, group or notes exceed the supported limits."
            return
        }
        item.name = cleanName
        item.group = cleanGroup
        item.notes = notes
        item.isFavorite = favorite
        do { try await store.update(item); await load() }
        catch { message = error.localizedDescription }
    }

    func editSource(for profile: VPNProfile) async -> String? {
        do { return try await store.runtimeConfig(for: profile) }
        catch { message = "Cannot open configuration: \(error.localizedDescription)"; return nil }
    }

    func saveSource(for profile: VPNProfile, text: String) async -> Bool {
        guard !connected && !connecting else {
            message = "Disconnect before editing a VPN profile."
            return false
        }
        do {
            try await store.revise(profile, text: text)
            message = "Configuration saved and previous version archived."
            return true
        } catch {
            message = "Configuration was not saved: \(error.localizedDescription)"
            return false
        }
    }

    func revisions(for profile: VPNProfile) async -> [ProfileRevision] {
        do { return try await store.revisions(for: profile) }
        catch { message = "Cannot read profile history: \(error.localizedDescription)"; return [] }
    }

    func restoreSource(for profile: VPNProfile, revision: String) async -> Bool {
        guard !connected && !connecting else {
            message = "Disconnect before restoring a VPN profile."
            return false
        }
        do {
            try await store.restore(profile, revision: revision)
            message = "Previous configuration restored. The newer version was archived."
            return true
        } catch {
            message = "Restore refused: \(error.localizedDescription)"
            return false
        }
    }

    func deleteSelected() async {
        guard let item = selected else { return }
        do { try await store.delete(id: item.id); KeychainVault.remove(id: item.id); selectedID = nil; await load() }
        catch { message = error.localizedDescription }
    }

    func refreshRules() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let candidate = try await updater.fetchCandidate()
            if connected {
                let response = await helper.updateRules(candidate.routes.map(\.description).joined(separator: "\n"))
                guard response == "Rules applied" || response == "NO_ACTIVE_SPLIT" else {
                    message = "Existing routes unchanged. \(response)"
                    return
                }
            }
            try await updater.commit(candidate)
            rules = candidate
            ruleSnapshots = try await updater.snapshots()
            message = "Validated and cached \(candidate.routes.count) IPv4 networks."
        } catch { message = "Update failed; old rules preserved. \(error.localizedDescription)" }
    }

    func checkForUpdates() async {
        do {
            let release = try await UpdateChecker.latestRelease()
            guard ReleaseAssetPolicy.isApprovedReleasePage(release.html_url) else {
                message = "Release metadata failed URL verification."
                return
            }
            availableReleasePage = release.html_url
            guard let remote = ReleaseVersion(release.tag_name),
                  let installed = ReleaseVersion(
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                  ) else {
                message = "Release version could not be verified."
                return
            }
            if remote <= installed {
                availableInstaller = nil
                message = "VPN Navigator \(installed) is up to date."
                return
            }
            availableInstaller = release.trustedInstallerURL
            message = "VPN Navigator \(remote) is available. Downloading requires your approval; installation uses the macOS Installer."
        } catch {
            message = "Cannot check for application updates: \(error.localizedDescription)"
        }
    }
    func downloadVerifiedUpdate() async {
        guard !busy, let url = availableInstaller else { return }
        guard !connected && !connecting, helper.installationStatus != .enabled else {
            message = "Disconnect the VPN and disable VPN Navigator background services before upgrading."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let local = try await InstallerUpdate.prepare(url)
            // Never run /usr/sbin/installer automatically; the user remains
            // in control of privileged changes via the macOS Installer UI.
            let accepted = NSWorkspace.shared.open(local)
            message = accepted ?
                "Installer opened. Review and approve the signed update in macOS." :
                "Verified installer saved at \(local.path); open it in Finder to continue."
        } catch {
            message = "Update verification failed: \(error.localizedDescription)"
        }
    }
    func viewReleasePage() {
        guard let url = availableReleasePage,
              ReleaseAssetPolicy.isApprovedReleasePage(url) else { return }
        NSWorkspace.shared.open(url)
    }
    func retryNetworkRecovery() async {
        guard !connected && !connecting else {
            message = "Disconnect the VPN before attempting route recovery."
            return
        }
        message = await helper.recoverOrphanedRoutes()
        await refreshConnectionStatus()
    }
    func disableServices() async {
        guard !connected && !connecting else {
            message = "Disconnect VPN before disabling background services."
            return
        }
        do {
            try await SMAppService.agent(plistName: "com.javafancn.vpn-navigator.rules.plist").unregister()
            try helper.unregister()
            await refreshConnectionStatus()
            message = "VPN Navigator background services have been unregistered."
        } catch {
            message = "Service removal requires attention: \(error.localizedDescription)"
        }
    }
    func restoreRuleSnapshot(_ id: UUID) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let restored = try await updater.archivedRules(id: id)
            if let previous = try await updater.cached() {
                try RuleUpdater.validateChange(previous: previous, next: restored)
            }
            if connected {
                let result = await helper.updateRules(
                    restored.routes.map(\.description).joined(separator: "\n"))
                guard result == "Rules applied" || result == "NO_ACTIVE_SPLIT" else {
                    message = "Previous rules preserved: \(result)"
                    return
                }
            }
            try await updater.commit(restored)
            rules = restored
            ruleSnapshots = try await updater.snapshots()
            message = "Previous China IPv4 rules restored."
        } catch {
            message = "Rule rollback refused: \(error.localizedDescription)"
        }
    }

    func requestHelper() {
        do {
            try helper.requestRegistration()
            try SMAppService.agent(plistName: "com.javafancn.vpn-navigator.rules.plist").register()
            helperStatus = String(describing: helper.installationStatus)
            message = "Enable the background helper in System Settings if requested. A signed .app distribution is required."
        } catch { message = "Helper registration failed: \(error.localizedDescription)" }
    }
    func refreshConnectionStatus() async {
        helperStatus = String(describing: helper.installationStatus)
        if helper.installationStatus == .enabled {
            connectionStatus = await helper.status()
        } else {
            connectionStatus = "disconnected: Privileged helper not enabled"
        }
    }
    func connectSelected() async {
        guard !busy, let selected else { return }
        busy = true; defer { busy = false }
        do {
            let text = try await store.runtimeConfig(for: selected)
            _ = try ProfileSafety.validate(text)
            if selected.mode == .chinaDirect && rules == nil {
                message = "Download China IPv4 rules before connecting."
                return
            }
            if rememberCredentials && (username.isEmpty || password.isEmpty),
               let secret = KeychainVault.load(id: selected.id) {
                username = secret.username
                password = secret.password
            }
            if rememberCredentials && !password.isEmpty {
                try KeychainVault.store(.init(username: username, password: password), id: selected.id)
            }
            let rulesText = (rules?.routes ?? []).map(\.description).joined(separator: "\n")
            let result = await helper.connect(profile: text, mode: selected.mode, rules: rulesText,
                                              username: username, password: password)
            password = "" // never retain passwords in UI state after a connection attempt
            if result.hasPrefix("ERROR:") { message = result }
            else { connectionStatus = "connecting: \(result)" }
        } catch { message = "Profile rejected: \(error.localizedDescription)" }
    }
    func disconnect() async {
        let response = await helper.disconnect()
        if response.hasPrefix("ERROR:") { message = response }
        await refreshConnectionStatus()
    }
    func exportPreview() async {
        guard let profile = selected else { return }
        do {
            let original = try await store.original(for: profile)
            let generated = try ProfileCompiler.render(original: original, mode: profile.mode, rules: rules)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = profile.name + "-preview.ovpn"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try generated.write(to: url, atomically: true, encoding: .utf8)
            message = "Exported a preview; no system routes were modified."
        } catch { message = "Export failed: \(error.localizedDescription)" }
    }
}

@main
struct VPNNavigatorApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("VPN Navigator") {
            MainView().environmentObject(model)
                .frame(minWidth: 780, minHeight: 500)
        }
        MenuBarExtra("VPN Navigator", systemImage: "network") {
            Text("VPN Navigator")
            Text(model.connectionStatus).foregroundStyle(.secondary)
            Divider()
            if model.connected || model.connecting {
                Button("Disconnect") { Task { await model.disconnect() } }
            } else {
                Button("Connect Selected Profile") { Task { await model.connectSelected() } }
                    .disabled(model.selected == nil)
            }
            Button("Check China IP Rules") { Task { await model.refreshRules() } }
            Divider()
            Text("\(model.profiles.count) saved profiles")
        }
        Settings {
            Form {
                LabeledContent("VPN engine", value: "Bundled OpenVPN CLI (requires signed distribution)")
                LabeledContent("Background helper", value: model.helperStatus)
                Button("Enable Privileged Helper…") { model.requestHelper() }
                Button("Disable Background Services…") { Task { await model.disableServices() } }
                Button("Attempt Safe Network Recovery…") { Task { await model.retryNetworkRecovery() } }
                Button("Check for App Updates") { Task { await model.checkForUpdates() } }
                Button("Download Verified Update…") { Task { await model.downloadVerifiedUpdate() } }
                    .disabled(model.availableInstaller == nil || model.busy)
                Button("View Release Notes…") { model.viewReleasePage() }
                    .disabled(model.availableReleasePage == nil)
                Text("This developer SwiftPM build cannot register a launch daemon by itself. Use the signed app bundle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(width: 540)
            .padding()
        }
    }
}
