import SwiftUI
import VPNNavigatorCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing = false
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                Section("Profiles") {
                    ForEach(model.profiles) { profile in
                        Label(profile.name, systemImage: "network").tag(profile.id)
                    }
                }
                Section("Actions") {
                    Button { importing = true } label: { Label("Import .ovpn", systemImage: "plus") }
                }
                Section("System") {
                    Label(model.helperStatus, systemImage: "lock.shield")
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
        .task {
            while !Task.isCancelled {
                await model.refreshConnectionStatus()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.init(filenameExtension: "ovpn")!],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let files):
                Task { for file in files { await model.importFile(file) } }
            case .failure(let error):
                model.message = error.localizedDescription
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
                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.connectionStatus, systemImage: model.connected ? "checkmark.shield" : "circle.dotted")
                            .foregroundStyle(model.connected ? .green : .secondary)
                        TextField("Username (if required)", text: $model.username)
                        SecureField("Password (if required)", text: $model.password)
                        HStack {
                            Button("Connect") { Task { await model.connectSelected() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.busy || model.connected || model.connecting)
                            Button("Disconnect") { Task { await model.disconnect() } }
                                .disabled(!model.connected && !model.connecting)
                        }
                    }.padding(8)
                }
                GroupBox("Network policy") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: Binding(
                            get: { profile.mode },
                            set: { value in Task { await model.setMode(value) } }
                        )) {
                            Text("Follow original profile").tag(RoutingMode.original)
                            Text("Full VPN").tag(RoutingMode.fullVPN)
                            Text("Mainland China direct").tag(RoutingMode.chinaDirect)
                        }.pickerStyle(.radioGroup)
                        Text("Change the policy before reconnecting. An active connection keeps its existing policy.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("China IPv4 rules") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(model.rules.map { "\($0.routes.count) validated networks" } ?? "No cached rules")
                            Spacer()
                            Button("Update Now") { Task { await model.refreshRules() } }
                                .disabled(model.busy)
                        }
                        Text("Updates may be applied to an active split-tunnel session; errors retain the last validated rules.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                HStack {
                    Button("Export configuration preview…") { Task { await model.exportPreview() } }
                        .disabled(profile.mode == .chinaDirect && model.rules == nil)
                    Spacer()
                    Button("Remove Profile", role: .destructive) { Task { await model.deleteSelected() } }
                }
                Text("The privileged helper requires a signed app bundle and installed OpenVPN CLI. Native route and DNS operations must be validated on your Mac before relying on this as a production VPN.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(25).frame(maxWidth: 850, alignment: .leading)
        }
        .navigationTitle(profile.name)
    }
}
