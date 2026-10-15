import SwiftUI
import VPNNavigatorCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing = false
    @State private var searchText = ""
    private var shownProfiles: [VPNProfile] {
        let filtered = model.profiles.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.group.localizedCaseInsensitiveContains(searchText) ||
            $0.sourceFilename.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private var groups: [String] { Array(Set(shownProfiles.map(\.group))).sorted() }
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(groups, id: \.self) { group in
                    Section(group) {
                        ForEach(shownProfiles.filter { $0.group == group }) { profile in
                            Label(profile.name, systemImage: profile.isFavorite ? "star.fill" : "network")
                                .tag(profile.id)
                        }
                    }
                }
                Section("Actions") {
                    Button { importing = true } label: { Label("Import .ovpn", systemImage: "plus") }
                }
                Section("Tools") {
                    NavigationLink { NetworkDiagnosticsView() } label: {
                        Label("Network Diagnostics", systemImage: "stethoscope")
                    }
                }
                Section("System") {
                    Label(model.helperStatus, systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("VPN Navigator")
            .searchable(text: $searchText, prompt: "Search profiles")
        } detail: {
            if let selected = model.selected {
                ProfileDetail(profile: selected).id(selected.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "network").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("No VPN profile selected").font(.title2)
                    Text("Import an .ovpn configuration to get started.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var draftName = ""
    @State private var draftGroup = ""
    @State private var draftNotes = ""
    @State private var draftFavorite = false
    @State private var editorText = ""
    @State private var showingEditor = false
    @State private var history: [ProfileRevision] = []

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
                GroupBox("Profile details") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Display name", text: $draftName)
                        TextField("Group", text: $draftGroup)
                        Toggle("Favorite", isOn: $draftFavorite)
                        TextField("Notes", text: $draftNotes)
                        HStack {
                            Spacer()
                            Button("Save Details") {
                                Task {
                                    await model.updateMetadata(name: draftName,
                                        group: draftGroup, notes: draftNotes, favorite: draftFavorite)
                                }
                            }
                        }
                    }.padding(8)
                }
                GroupBox("Configuration & versions") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Button("Edit .ovpn…") {
                                Task {
                                    if let source = await model.editSource(for: profile) {
                                        editorText = source
                                        showingEditor = true
                                    }
                                }
                            }
                            Spacer()
                            Button("Refresh History") {
                                Task { history = await model.revisions(for: profile) }
                            }
                        }
                        Text("The editor may display private keys. Revisions are kept only in the private local profile repository.")
                            .font(.caption).foregroundStyle(.secondary)
                        if history.isEmpty {
                            Text("No previous versions yet").foregroundStyle(.secondary)
                        }
                        ForEach(history.prefix(10)) { revision in
                            HStack {
                                Text(revision.createdAt, style: .date)
                                Text(revision.createdAt, style: .time)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") {
                                    Task {
                                        if await model.restoreSource(for: profile, revision: revision.filename) {
                                            history = await model.revisions(for: profile)
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(8)
                }
                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.connectionStatus, systemImage: model.connected ? "checkmark.shield" : "circle.dotted")
                            .foregroundStyle(model.connected ? .green : .secondary)
                        TextField("Username (if required)", text: $model.username)
                        SecureField("Password (if required)", text: $model.password)
                        Toggle("Remember credentials in macOS Keychain", isOn: $model.rememberCredentials)
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
                        if !model.ruleSnapshots.isEmpty {
                            Divider()
                            Text("Rule history").font(.headline)
                            ForEach(model.ruleSnapshots.prefix(5)) { snapshot in
                                HStack {
                                    Text(snapshot.savedAt, style: .date)
                                    Text("\(snapshot.routeCount) networks")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Restore") {
                                        Task { await model.restoreRuleSnapshot(snapshot.id) }
                                    }
                                    .disabled(model.busy)
                                }
                            }
                        }
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
        .sheet(isPresented: $showingEditor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit OpenVPN Configuration").font(.title2.bold())
                Text("This configuration may include private keys. Unsafe scripts and unsupported options cannot be saved. Changes apply after reconnecting.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $editorText)
                    .font(.system(.body, design: .monospaced))
                    .border(Color.secondary.opacity(0.3))
                HStack {
                    Button("Cancel") {
                        editorText = ""
                        showingEditor = false
                    }
                    Spacer()
                    Button("Save Version") {
                        Task {
                            if await model.saveSource(for: profile, text: editorText) {
                                editorText = ""
                                history = await model.revisions(for: profile)
                                showingEditor = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
            .frame(minWidth: 720, minHeight: 530)
        }
        .onAppear {
            draftName = profile.name
            draftGroup = profile.group
            draftNotes = profile.notes
            draftFavorite = profile.isFavorite
            Task { history = await model.revisions(for: profile) }
        }
    }
}
