import SwiftUI
import VPNNavigatorCore

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var selectedID: UUID?
    @Published var rules: RuleSet?
    @Published var busy = false
    @Published var message: String?
    private let root: URL
    private let store: ProfileStore
    private let updater: RuleUpdater

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VPNNavigator", isDirectory: true)
        root = support
        store = ProfileStore(root: support.appendingPathComponent("Profiles"))
        updater = RuleUpdater(folder: support.appendingPathComponent("Rules"))
        Task { await load() }
    }
    var selected: VPNProfile? { profiles.first { $0.id == selectedID } }
    func load() async {
        do {
            profiles = try await store.list()
            if selectedID == nil { selectedID = profiles.first?.id }
            rules = try await updater.cached()
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
    func deleteSelected() async {
        guard let item = selected else { return }
        do { try await store.delete(id: item.id); selectedID = nil; await load() }
        catch { message = error.localizedDescription }
    }
    func refreshRules() async {
        busy = true; defer { busy = false }
        do {
            rules = try await updater.refresh()
            message = "Validated \(rules!.routes.count) IPv4 networks. Rules are cached; system routes are unchanged."
        } catch { message = "Update failed; old rules preserved. \(error.localizedDescription)" }
    }
    func exportPreview() async {
        guard let profile = selected else { return }
        do {
            let original = try await store.original(for: profile)
            let generated = try ProfileCompiler.render(original: original, mode: profile.mode, rules: rules)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = profile.name + "-preview.ovpn"
            panel.allowedContentTypes = [.init(filenameExtension: "ovpn")!]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try generated.write(to: url, atomically: true, encoding: .utf8)
            message = "Exported a preview profile. Not imported into OpenVPN and not connected."
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
            Text("VPN connection not configured").foregroundStyle(.secondary)
            Divider()
            Button("Check China IP Rules") { Task { await model.refreshRules() } }
            Divider()
            Text("\(model.profiles.count) saved profiles")
        }
        Settings {
            Form {
                LabeledContent("VPN engine", value: "Not installed (foundation build)")
                LabeledContent("Rule source", value: "chnroutes2")
                LabeledContent("Network changes", value: "Disabled")
            }
            .formStyle(.grouped)
            .frame(width: 450)
            .padding()
        }
    }
}
