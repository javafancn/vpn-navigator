import SwiftUI
import UniformTypeIdentifiers
import VPNNavigatorCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing = false
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                Section("Profiles") {
                    ForEach(model.profiles) { profile in
                        Label(profile.name, systemImage: "network")
                            .tag(profile.id)
                    }
                }
                Section("Actions") {
                    Button { importing = true } label: { Label("Import .ovpn", systemImage: "plus") }
                }
                Section("Status") {
                    Label("VPN engine not installed", systemImage: "shield.slash")
                        .foregroundStyle(.secondary)
                    Label("Route modifications disabled", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("VPN Navigator")
        } detail: {
            if let selected = model.selected {
                ProfileDetail(profile: selected)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "network").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("No VPN profile selected").font(.title2)
                    Text("Import an .ovpn configuration to get started.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.init(filenameExtension: "ovpn")!],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files):
                Task { for file in files { await model.importFile(file) } }
            case .failure(let error): model.message = error.localizedDescription
            }
        }
        .alert("VPN Navigator", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

private struct ProfileDetail: View {
    @EnvironmentObject private var model: AppModel
    let profile: VPNProfile
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 35)).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(profile.name).font(.title2.bold())
                        Text(profile.sourceFilename).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                GroupBox("VPN status") {
                    HStack {
                        Label("Not connected", systemImage: "circle.dotted")
                        Spacer()
                        Text("Engine integration pending").foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Network policy") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: Binding(
                            get: { profile.mode },
                            set: { newMode in Task { await model.setMode(newMode) } }
                        )) {
                            Text("Original profile").tag(RoutingMode.original)
                            Text("Full VPN").tag(RoutingMode.fullVPN)
                            Text("Mainland China direct").tag(RoutingMode.chinaDirect)
                        }
                        .pickerStyle(.radioGroup)
                        Text("Policies here are saved only. No system routes are changed in this build.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Mainland China IPv4 rules") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(model.rules.map { "\($0.routes.count) validated networks" } ?? "No cached rules")
                            Spacer()
                            Button("Check for Updates") { Task { await model.refreshRules() } }
                                .disabled(model.busy)
                        }
                        Text("Rule updates never disconnect your VPN in this foundation build because routes are not yet applied.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                HStack {
                    Button("Export configuration preview…") { Task { await model.exportPreview() } }
                        .disabled(profile.mode == .chinaDirect && model.rules == nil)
                    Spacer()
                    Button("Remove Profile", role: .destructive) { Task { await model.deleteSelected() } }
                }
                Text("This preview is not a production VPN client. Connection controls will be enabled only after the privileged helper passes integration tests.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(25)
            .frame(maxWidth: 850, alignment: .leading)
        }
        .navigationTitle(profile.name)
    }
}
