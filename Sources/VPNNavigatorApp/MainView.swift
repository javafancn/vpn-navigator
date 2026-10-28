import SwiftUI
import Darwin
import VPNNavigatorCore
import UniformTypeIdentifiers

// One native macOS workspace with clear separation between available
// features and previews. Uses system materials on macOS 13+ without
// assuming the macOS 26-only Liquid Glass APIs.
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case overview, profiles, routing, diagnostics, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L10n.text("连接总览")
        case .profiles: return L10n.text("配置文件")
        case .routing: return L10n.text("路由与规则")
        case .diagnostics: return L10n.text("网络诊断")
        case .settings: return L10n.text("设置与维护")
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "circle.hexagongrid.fill"
        case .profiles: return "square.stack.3d.up"
        case .routing: return "point.3.connected.trianglepath.dotted"
        case .diagnostics: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspaceCommands: WorkspaceCommandRouter
    @StateObject private var navigation: WorkspaceNavigation
    private var tab: WorkspaceTab {
        get { navigation.tab }
        nonmutating set { navigation.select(newValue) }
    }
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sidebarSelection

    /// The UI snapshot argument selects a real application page for macOS
    /// screenshot checks. It never changes connectivity or network state.
    init(navigation: WorkspaceNavigation? = nil) {
        let state = navigation ?? WorkspaceNavigation()
        if let value = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--vpnnav-ui-tab=") })?
            .split(separator: "=", maxSplits: 1).last,
           let initialTab = WorkspaceTab(rawValue: String(value)) {
            state.select(initialTab)
        }
        _navigation = StateObject(wrappedValue: state)
    }

    var body: some View {
        ZStack {
            GlassAtmosphere(onWindow: {
                workspaceCommands.attach($0)
                MainWindowPresentation.shared.attach($0)
            })
            HStack(spacing: 0) {
                sidebar.frame(width: 228)
                Rectangle().fill(Color.white.opacity(0.24)).frame(width: 1)
                VStack(spacing: 0) {
                    if let issue = model.profileIndexIssue {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(issue).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button(L10n.text("查看恢复…")) { Task { await model.inspectProfileIndex() } }
                                .buttonStyle(ReferenceSecondaryButton()).disabled(model.busy || model.profileTransferInProgress)
                        }.padding(12).glassCard(cornerRadius: 12).padding(.horizontal, 16).padding(.top, 16)
                    }
                    Group {
                        switch tab {
                        case .overview: ConnectionOverview()
                        case .profiles: ProfileLibrary(searchRequest: navigation.searchRequest, onImport: {
                            if model.canChooseProfileFiles { model.profilePickerPresented = true }
                        })
                        case .routing: RoutingWorkspace()
                        case .diagnostics: NetworkDiagnosticsView()
                        case .settings: SystemSettingsPane()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .referenceWorkspaceSurface()
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                    .padding(.top, 26)
                    .padding(.bottom, 16)
                    .id(tab)
                    .transition(.opacity)
                    .animation(GlassMotion.page(reduceMotion), value: tab)

                }
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { model.receiveProfileDrop($0) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18).strokeBorder(GlassPalette.blue, lineWidth: 2)
                    .padding(10).overlay {
                        Label(L10n.text("松开以导入 .ovpn 配置"), systemImage: "square.and.arrow.down")
                            .font(.system(size: 18, weight: .semibold)).padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }.allowsHitTesting(false)
            }
        }
        .onChange(of: model.workspaceNavigationBlocked) { _ in workspaceCommands.refresh() }
        .preferredColorScheme(.light)
        .environment(\.locale, L10n.locale)
        .onAppear {
            if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("self-test") }) {
                FileHandle.standardError.write(Data("Main scene appeared\n".utf8))
            }
            workspaceCommands.configure(model: model, navigation: navigation)
            if ProcessInfo.processInfo.arguments.contains("--vpnnav-workspace-accessibility-self-test") {
                Task {
                    do { try await WorkspaceAccessibilitySelfTest.run(model: model, navigation: navigation, router: workspaceCommands); Darwin.exit(0) }
                    catch { print("Workspace accessibility self-test failed: \(error)"); Darwin.exit(1) }
                }
            }
            model.quickAccess.openMainWindow = {
                MainWindowPresentation.shared.show { openWindow(id: "main") }
            }
            if ProcessInfo.processInfo.arguments.contains("--vpnnav-overview-self-test"), OverviewSelfTest.begin() {
                Task {
                    do { try await OverviewSelfTest.run(model: model); Darwin.exit(0) }
                    catch { print("Overview self-test failed: \(error)"); Darwin.exit(1) }
                }
            }
            if model.overviewIsFixture { model.showOverviewSnapshot() }
            if ProcessInfo.processInfo.arguments.contains("--vpnnav-status-bar-self-test"), StatusBarSelfTest.begin() {
                Task {
                    do { try await StatusBarSelfTest.run(model: model); Darwin.exit(0) }
                    catch { print("Status bar and window lifecycle self-test failed: \(error)"); Darwin.exit(1) }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-quick-access-snapshot") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.quickAccess.show() }
            }
            if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
               ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") {
                if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-library-filter-snapshot") {
                    model.profileLibrary.scope = .group("节点")
                    model.selectedID = model.libraryProfiles.first?.id
                } else if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-library-empty-snapshot") {
                    model.profileLibrary.scope = .favorites; model.profileLibrary.query = "工作"
                }
            }
            if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
               ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot"), !model.profiles.isEmpty {
                if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-language-settings-snapshot") {
                    model.showingLanguageSettings = true
                } else if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-keyboard-help-snapshot") {
                    model.showingKeyboardHelp = true
                } else if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-custom-routes-snapshot") ||
                   ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-route-explanation-snapshot") {
                    model.profiles[0].customRules = [CustomRouteRule(cidr: "9.9.9.9/32", action: .direct), CustomRouteRule(cidr: "10.66.0.0/16", action: .vpn)]
                    model.profiles[0].mode = .fullVPN
                    model.selectedID = model.profiles[0].id
                    if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-custom-routes-snapshot") { model.customRuleEditorProfile = model.profiles[0] }
                    else { model.showingRouteExplanation = true }
                } else if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-public-egress-snapshot") {
                    model.showingPublicEgress = true
                } else if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-connection-history-snapshot") {
                    model.connectionHistory.showSnapshot(profiles: model.profiles)
                    model.showingConnectionHistory = true
                } else if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-profile-health-snapshot") {
                    model.showProfileHealth(model.profiles[0].id)
                } else if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-profile-update-snapshot") {
                    model.showProfileHealth(model.profiles[0].id, updating: true)
                } else if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-profile-backup-snapshot") { model.showingProfileBackup = true }
                else if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-smart-connection-snapshot") { model.showingSmartConnection = true }
                else if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-troubleshooting-snapshot") { model.showingTroubleshooting = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-profile-recovery-snapshot") {
                Task { await model.showProfileIndexRecoverySnapshot() }
            }
            if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-import-report-snapshot") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.showImportReportSnapshot() }
            }
            if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-import-review-snapshot"),
               ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") {
                var request = ProfileOpenQueue()
                request.append([URL(fileURLWithPath: "/ui-fixture/工作网络.ovpn"),
                                URL(fileURLWithPath: "/ui-fixture/家庭网络.ovpn"),
                                URL(fileURLWithPath: "/ui-fixture/工作网络.ovpn"),
                                URL(fileURLWithPath: "/ui-fixture/说明.txt")])
                model.receiveProfileOpenRequest(request)
            }
        }
        .task(id: model.incomingPresentationReady) {
            guard model.incomingPresentationReady else { return }
            // Let the previous native sheet finish dismissing first.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            model.presentIncomingProfiles()
        }
        .fileImporter(isPresented: $model.profilePickerPresented,
                      allowedContentTypes: [.init(filenameExtension: "ovpn")!],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task {
                    await model.importFiles(urls)
                    tab = .profiles
                }
            case .failure(let error):
                model.message = error.localizedDescription
            }
        }
        .sheet(isPresented: $model.showingLanguageSettings) { LanguageSettingsView() }
        .sheet(isPresented: $model.showingKeyboardHelp) { KeyboardHelpView() }
        .sheet(isPresented: $model.showingAccountCredentials) { AccountCredentialsView().environmentObject(model) }
        .sheet(item: $model.authenticationChallenge) { challenge in
            AuthenticationChallengeView(challenge: challenge).id(challenge.id).environmentObject(model)
        }
        .sheet(isPresented: $model.showingMaintenance) { MaintenanceAssistantView().environmentObject(model) }
        .sheet(isPresented: $model.showingSetup) { SetupAssistantView().environmentObject(model) }
        .sheet(isPresented: $model.showingProfileBackup) { ProfileBackupView(model: model) }
        .sheet(item: $model.profileHealthTarget) { profile in ProfileHealthView(model: model, profile: profile, updating: model.profileUpdateRequested) }
        .sheet(isPresented: $model.showingSmartConnection) { SmartConnectionSettingsView().environmentObject(model) }
        .sheet(isPresented: $model.showingPreferences) { ClientPreferencesView().environmentObject(model) }
        .sheet(isPresented: $model.showingProfileIndexRecovery) { ProfileIndexRecoveryView().environmentObject(model) }
        .sheet(item: $model.customRuleEditorProfile) { profile in CustomRoutingEditorView(profile: profile).environmentObject(model) }
        .sheet(isPresented: $model.showingRouteExplanation) { RouteExplanationView().environmentObject(model) }
        .sheet(isPresented: $model.showingTroubleshooting) { OneClickTroubleshootingView().environmentObject(model) }
        .sheet(isPresented: $model.showingPublicEgress) { PublicEgressView().environmentObject(model) }
        .sheet(isPresented: $model.showingDiagnostics) { DiagnosticHistoryView().environmentObject(model) }
        .sheet(isPresented: $model.showingConnectionHistory) { ConnectionHistoryView().environmentObject(model) }
        .sheet(isPresented: $model.showingImportReport) {
            if model.reviewingIncomingProfiles { ProfileOpenReviewView().environmentObject(model) }
            else { ProfileImportReportView().environmentObject(model) }
        }
        .onChange(of: model.showingImportReport) { shown in if shown { tab = .profiles } }
        .alert("VPN Navigator", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button(L10n.text("确定")) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN Navigator").font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text(L10n.text("网络连接控制台")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.top, 42)
            .padding(.bottom, 30)

            Text(L10n.text("工作区"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
                .padding(.bottom, 10)

            ForEach(WorkspaceTab.allCases) { item in
                Button { tab = item } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(tab == item ? Color.white : GlassPalette.blue)
                            .frame(width: 24)
                        Text(item.title)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(tab == item ? Color.white : GlassPalette.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 44)
                    .background {
                        if tab == item {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(LinearGradient(colors: [
                                    Color(red: 0.12, green: 0.53, blue: 1),
                                    Color(red: 0.03, green: 0.39, blue: 0.91)
                                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .shadow(color: GlassPalette.blue.opacity(0.15), radius: 4, y: 2)
                                .matchedGeometryEffect(id: "workspace-selection", in: sidebarSelection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(ReferenceQuietButton())
                .accessibilityIdentifier("workspace-" + item.rawValue)
                .accessibilityLabel(item.title)
                .accessibilityValue(tab == item ? L10n.text("已选择") : L10n.text("未选择"))
                .accessibilityAddTraits(tab == item ? .isSelected : [])
                .padding(.horizontal, 15)
                .padding(.bottom, 5)
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 15) {
                Button { model.profilePickerPresented = true } label: {
                    Label(L10n.text("导入配置"), systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ReferenceSecondaryButton())
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.canChooseProfileFiles)
                Text(model.profileDropLoading ? L10n.text("正在接收文件…") : L10n.text("可将 .ovpn 文件拖入窗口"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !model.incomingProfiles.isEmpty && !model.reviewingIncomingProfiles {
                    Text(L10n.format("待处理：{0} 个配置", [String(describing: model.incomingProfiles.urls.count)]))
                        .font(.system(size: 11)).foregroundStyle(GlassPalette.blue)
                }
                Rectangle().fill(GlassPalette.ink.opacity(0.07)).frame(height: 0.75)
                HStack(spacing: 8) {
                    Circle().fill(model.connected ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(model.connected ? L10n.text("VPN 已连接") : model.connecting ? L10n.text("正在连接…") : L10n.text("VPN 未连接"))
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text(L10n.format("{0} 个配置", [String(describing: model.profiles.count)]))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)

        }
        .background {
            GlassSurface.sidebar.opacity(0.04)
        }
        .animation(GlassMotion.selection(reduceMotion), value: tab)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.36)).frame(width: 1)
        }
    }


}

struct WorkspaceHeading: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: ReferenceType.pageTitle, weight: .bold))
                    .foregroundStyle(GlassPalette.ink)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct VPNPanel<Content: View>: View {
    @Environment(\.colorScheme) private var appearance
    let title: String
    let symbol: String
    private let content: Content
    var minContentHeight: CGFloat = 0
    var fillHeight: Bool = false
    init(_ title: String, symbol: String, minContentHeight: CGFloat = 0,
         fillHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.minContentHeight = minContentHeight
        self.fillHeight = fillHeight
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: ReferenceType.panelTitle, weight: .semibold))
                .foregroundStyle(appearance == .dark ? Color.white.opacity(0.91) : GlassPalette.ink.opacity(0.94))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: minContentHeight, alignment: .topLeading)
        .padding(15)
        .frame(maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .glassCard(cornerRadius: 15)
    }
}

private struct ConnectionOverview: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmSwitch = false
    @State private var showingCredentials = false

    private var hasError: Bool { model.connectionStatus.hasPrefix("failed:") }
    private var statusTitle: String {
        model.connected ? L10n.text("已连接") : model.firewallRecoveryRequired && !model.connecting ? L10n.text("网络保护待处理") : model.stopping ? L10n.text("正在断开") : model.connecting ? L10n.text("正在连接") : hasError ? L10n.text("连接需检查") : L10n.text("未连接")
    }
    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "— MB" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                WorkspaceHeading(title: L10n.text("连接总览"), subtitle: model.overviewIsFixture ? L10n.text("界面预览：合成数据，未建立 VPN") : L10n.text("清晰掌控当前 VPN 状态与网络策略"), symbol: "globe.americas.fill")
                Spacer()
                Button(L10n.text("会话质量与历史…")) { model.showingConnectionHistory = true }.buttonStyle(ReferenceSecondaryButton())
            }.padding(.bottom, 4)
            HStack(spacing: 12) {
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button {
                        guard model.selected != nil || model.connected else {
                            model.message = L10n.text("请先导入并选择一个 .ovpn 配置文件。")
                            return
                        }
                        Task {
                            if model.connected || model.connecting || model.firewallRecoveryRequired { await model.disconnect() }
                            else { await model.connectSelected() }
                        }
                    } label: { ReferencePowerOrb() }
                    .buttonStyle(ReferenceQuietButton(cornerRadius: 110, hoverOpacity: 0.04))
                    .disabled(model.stopping || (model.busy && !model.connecting && !model.connected && !model.firewallRecoveryRequired))
                    .accessibilityIdentifier("vpn-power")
                    .accessibilityLabel(model.firewallRecoveryRequired && !model.connected && !model.connecting ? L10n.text("解除断线保护") : model.connected ? L10n.text("断开 VPN") : model.connecting ? L10n.text("取消连接") : L10n.text("连接 VPN"))
                    .accessibilityValue(statusTitle)
                    Text(statusTitle)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(model.connected ? Color.green : hasError ? Color.orange : GlassPalette.blue)
                    Text(model.connected ? L10n.text("VPN 连接已建立") : model.connecting ? L10n.text("点击上方按钮取消连接") : model.firewallRecoveryRequired ? L10n.text("点击上方按钮解除断线保护") : L10n.text("点击上方按钮开始连接"))
                        .font(.system(size: 16))
                        .foregroundStyle(model.connected ? Color.green : GlassPalette.ink.opacity(0.6))
                    if model.connected && model.activeProfileID != model.selectedID && model.selectedID != nil {
                        Button(L10n.text("切换到所选配置")) { confirmSwitch = true }
                            .buttonStyle(ReferenceSecondaryButton())
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 310)
                .glassCard(cornerRadius: 19, active: true)

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.3")
                            Text(L10n.text("快速连接")).fontWeight(.semibold)
                            Spacer()
                            Button { showingCredentials = true } label: {
                                Image(systemName: "key.horizontal")
                                    .font(.system(size: 14))
                                    .foregroundStyle(GlassPalette.ink.opacity(0.45))
                            }
                            .buttonStyle(.plain)
                            .help(L10n.text("身份验证")).accessibilityLabel(L10n.text("身份验证"))
                            .popover(isPresented: $showingCredentials) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(L10n.text("身份验证")).font(.headline)
                                    TextField(L10n.text("用户名"), text: $model.username).textFieldStyle(.plain).referenceInput()
                                    SecureField(L10n.text("密码"), text: $model.password).textFieldStyle(.plain).referenceInput()
                                    Toggle(L10n.text("保存在钥匙串"), isOn: $model.rememberCredentials)
                                }.padding(20).frame(width: 290)
                            }
                        }
                        .font(.system(size: 18))
                        quickRow(L10n.text("配置文件")) {
                            Menu {
                                ForEach(model.profiles) { profile in
                                    Button(profile.name) { model.selectedID = profile.id }
                                }
                            } label: {
                                selectionField(model.selected?.name ?? L10n.text("请选择配置"), stepper: true)
                            }
                                                        .menuIndicator(.hidden)
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("选择连接配置"))
                            .accessibilityValue(model.selected?.name ?? L10n.text("未选择"))
                            .disabled(model.profiles.isEmpty || model.busy)
                        }
                        quickRow(L10n.text("路由模式")) {
                            Menu {
                                ForEach(RoutingMode.allCases) { mode in
                                    Button(mode.title) { Task { await model.setMode(mode) } }
                                        .disabled(!model.canSetRoutingMode(mode, for: model.selectedID))
                                }
                            } label: {
                                selectionField(model.displayedRoutingMode(for: model.selectedID)?.title ?? L10n.text("待核验"), stepper: false)
                            }
                                                        .menuIndicator(.hidden)
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("选择路由模式"))
                            .accessibilityValue(model.displayedRoutingMode(for: model.selectedID)?.title ?? L10n.text("待核验"))
                            .disabled(model.selected == nil || model.busy || model.routingModeSwitching || model.connecting || model.stopping)
                        }
                        quickRow(L10n.text("源文件")) {
                            Text(model.selected?.sourceFilename ?? L10n.text("未选择配置"))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .referenceInput()
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .glassCard(cornerRadius: 18)

                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 29, weight: .regular))
                            .foregroundStyle(GlassPalette.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.activeProfile?.name ?? model.selected?.name ?? L10n.text("尚未选择配置"))
                                .font(.system(size: 15, weight: .medium)).lineLimit(1)
                            Text(model.activeProfile?.sourceFilename ?? model.selected?.sourceFilename ?? L10n.text("等待导入 .ovpn 文件"))
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            Label(bytes(model.traffic?.receivedBytes), systemImage: "arrow.down")
                            Label(bytes(model.traffic?.sentBytes), systemImage: "arrow.up")
                        }.font(.system(size: 12)).foregroundStyle(GlassPalette.blue)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 80)
                    .frame(maxWidth: .infinity)
                    .glassCard(cornerRadius: 16)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 310)
            }
            ConnectionOverviewCards()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GlassLayout.pageInset)
        .padding(.top, GlassLayout.pageTop)
        .padding(.bottom, 16)
        .confirmationDialog(L10n.text("切换 VPN 配置？"), isPresented: $confirmSwitch) {
            Button(L10n.text("断开当前连接并切换")) { Task { await model.switchToSelected() } }
            Button(L10n.text("取消"), role: .cancel) { }
        }
    }

    private func quickRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 16)).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            content()
        }
    }
    private func selectionField(_ title: String, stepper: Bool) -> some View {
        HStack {
            Text(title).lineLimit(1).foregroundStyle(GlassPalette.ink)
            Spacer(minLength: 0)
            Image(systemName: stepper ? "chevron.up.chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(stepper ? .white : GlassPalette.ink.opacity(0.5))
                .frame(width: 22, height: 26)
                .background(stepper ? GlassPalette.blue : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.referenceInput().contentShape(Rectangle())
    }

}

private struct ReferencePowerOrb: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.18))
                .frame(width: 194, height: 194)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.75))
            Circle().strokeBorder(GlassPalette.blue.opacity(0.18), lineWidth: 1.5)
                .frame(width: 180, height: 180)
            Circle().fill(LinearGradient(colors: [
                Color(red: 0.10, green: 0.65, blue: 1), GlassPalette.blue,
                Color(red: 0.04, green: 0.37, blue: 0.94)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 162, height: 162)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                .shadow(color: GlassPalette.blue.opacity(0.20), radius: 14, y: 7)
            Image(systemName: "power")
                .font(.system(size: 52, weight: .light)).foregroundStyle(.white)
        }.frame(width: 204, height: 204)
    }
}

private struct RoutingWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @State private var snapshotToRestore: RuleSnapshot?
    @State private var importingRules = false

    private func title(for mode: RoutingMode) -> String { mode.title }
    private func subtitle(for mode: RoutingMode) -> String {
        switch mode {
        case .original: return L10n.text("遵循配置文件及服务器下发的路由")
        case .fullVPN: return L10n.text("服务器承载的 IPv4／IPv6 默认流量走 VPN")
        case .chinaDirect: return L10n.text("中国 IPv4／IPv6 直连，其余默认流量走 VPN")
        }
    }

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: L10n.text("路由与规则"), subtitle: L10n.text("管理双栈 VPN 路由、国内规则和自定义例外"), symbol: "point.3.connected.trianglepath.dotted")
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(GlassPalette.blue)
                Text(L10n.text("当前配置")).foregroundStyle(.secondary)
                Text(model.selected?.name ?? L10n.text("尚未选择")).fontWeight(.medium)
                Spacer()
                Text(model.connected && model.selectedID == model.activeProfileID ? model.routingModeStatus : L10n.text("保存后在下次连接生效")).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.vertical, 4)
            HStack(spacing: 10) {
                Button(L10n.format("自定义规则 ({0})", [String(describing: model.selected?.customRules.filter(\.enabled).count ?? 0)])) { model.customRuleEditorProfile = model.selected }
                    .buttonStyle(ReferenceSecondaryButton()).disabled(model.selected == nil || model.profileTransferInProgress || model.busy)
                Button(L10n.text("路由解释…")) { model.showingRouteExplanation = true }.buttonStyle(ReferenceSecondaryButton())
                Button(L10n.text("一键排障…")) { model.showingTroubleshooting = true }.buttonStyle(ReferenceSecondaryButton())
                Spacer(minLength: 0)
            }.font(.system(size: 13))
            if model.connected, let count = model.activeCustomRuleCount {
                Text((model.activeIPStack?.title ?? L10n.text("地址族待核验")) + L10n.format(" · 本次自定义规则：{0} 条；编辑该配置需先断开。", [String(describing: count)]))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("路由模式")).font(.system(size: 20, weight: .semibold))
                    ForEach(RoutingMode.allCases) { mode in routeOption(mode) }
                    Spacer(minLength: 8)
                    Text(L10n.text("规则与全局直接切换，不主动重连。原始配置需先断开；收紧断线保护会重置网络连接。"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(width: max(280, (geometry.size.width - 62) * 0.43))
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .glassCard(cornerRadius: 18)
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.text("中国 IPv4 规则")).font(.system(size: 20, weight: .semibold))
                        HStack(alignment: .top, spacing: 16) {
                            GlassIcon(symbol: "globe.asia.australia", size: 67)
                            VStack(alignment: .leading, spacing: 16) {
                                ruleDetail(L10n.text("规则版本"), model.rulesUpdatedAt.map { $0.formatted(.dateTime.locale(L10n.locale).year().month().day()) } ?? L10n.text("未下载"))
                                ruleDetail(L10n.text("规则来源"), "chnroutes2")
                                ruleDetail(L10n.text("规则数量"), model.rules.map { L10n.format("{0} 条", [String(describing: $0.routes.count)]) } ?? L10n.text("未下载"))
                                ruleDetail(L10n.text("最后更新"), model.rulesUpdatedAt.map { $0.formatted(.dateTime.locale(L10n.locale).month().day().hour().minute()) } ?? L10n.text("尚无缓存"))
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 12) {
                            Button { Task { await model.refreshRules() } } label: {
                                Text(model.busy ? L10n.text("更新中…") : L10n.text("更新规则")).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ReferencePrimaryButton()).disabled(model.busy)
                            Menu {
                                Button(L10n.text("导入规则文件…")) { importingRules = true }
                                Divider()
                                ForEach(model.ruleSnapshots) { saved in
                                    Button(saved.savedAt.formatted(.dateTime.locale(L10n.locale).year().month().day().hour().minute())) { snapshotToRestore = saved }
                                }
                            } label: { Text(L10n.text("历史与导入")).frame(maxWidth: .infinity) }
                            .menuIndicator(.hidden)
                            .buttonStyle(ReferenceSecondaryButton())
                            .disabled(model.busy)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .glassCard(cornerRadius: 18)
                    HStack(alignment: .center, spacing: 12) {
                        GlassIcon(symbol: "shield.lefthalf.filled", size: 44)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L10n.text("中国 IPv6 规则")).font(.system(size: 16, weight: .semibold))
                                Spacer(minLength: 0)
                                Text("APNIC").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.gray.opacity(0.09), in: Capsule())
                            }
                            Text(model.ipv6Preview.map { L10n.format("{0} 条注册归属前缀 · 连接时应用", [String(describing: $0.routes.count)]) } ?? L10n.text("双栈规则模式连接前请先更新。"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Button { Task { await model.updateIPv6Preview() } } label: {
                            Image(systemName: "arrow.clockwise").foregroundStyle(GlassPalette.blue)
                        }.buttonStyle(.plain).disabled(model.busy).help(L10n.text("更新 IPv6 分流规则"))
                    }
                    .padding(16)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                    .glassCard(cornerRadius: 18)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 440)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GlassLayout.pageInset)
        .padding(.top, GlassLayout.pageTop)
        .padding(.bottom, 20)
        }
        .fileImporter(isPresented: $importingRules, allowedContentTypes: [.plainText]) { result in
            if case .success(let url) = result { Task { await model.importRules(url) } }
        }
        .confirmationDialog(L10n.text("恢复旧版 IPv4 规则？"), isPresented: Binding(
            get: { snapshotToRestore != nil }, set: { if !$0 { snapshotToRestore = nil } }
        )) {
            if let snapshot = snapshotToRestore {
                Button(L10n.text("确认恢复历史快照")) {
                    Task { await model.restoreRuleSnapshot(snapshot.id) }
                    snapshotToRestore = nil
                }
            }
            Button(L10n.text("取消"), role: .cancel) { snapshotToRestore = nil }
        } message: { Text(L10n.text("恢复会替换当前规则，已有受管连接的安全限制仍然适用。")) }
        }
    }

    private func routeOption(_ mode: RoutingMode) -> some View {
        let selected = model.displayedRoutingMode(for: model.selectedID)
        return Button {
            Task { await model.setMode(mode) }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: selected == mode ?
                      "largecircle.fill.circle" : "circle")
                    .font(.system(size: 26))
                    .foregroundStyle(selected == mode ?
                                     GlassPalette.blue : Color.gray)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title(for: mode))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle(for: mode))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(selected == mode ?
                        GlassPalette.blue.opacity(0.10) : Color.white.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected == mode ?
                                  GlassPalette.blue.opacity(0.12) :
                                  Color.white.opacity(0.14), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ReferenceQuietButton(cornerRadius: 12))
        .disabled(!model.canSetRoutingMode(mode, for: model.selectedID))
    }

    private func ruleDetail(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 14))
    }
}

struct SystemSettingsPane: View {
    @EnvironmentObject private var model: AppModel

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
    private var helperReady: Bool { model.helperStatus == L10n.text("已启用") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                WorkspaceHeading(title: L10n.text("设置与维护"),
                    subtitle: L10n.text("管理系统服务、应用更新与网络恢复"), symbol: "gearshape")
                    .padding(.bottom, 10)

                settingsSection(L10n.text("显示与语言"))
                VStack(spacing: 0) {
                    settingsRow(L10n.text("界面语言"), subtitle: L10n.text("跟随系统、简体中文或 English；下次启动后生效"), symbol: "globe") {
                        Button(L10n.text("选择语言…")) { model.showingLanguageSettings = true }.buttonStyle(ReferenceSecondaryButton())
                    }
                }.glassCard(cornerRadius: 15)
                settingsSection(L10n.text("系统与网络"))
                VStack(spacing: 0) {

                settingsRow(L10n.text("特权助手"),
                    subtitle: L10n.text("管理系统使用此配置所需的特权助手"),
                    symbol: "shield.lefthalf.filled") {
                    Menu {
                        Button(L10n.text("启用服务…")) { model.requestHelper() }
                        Button(L10n.text("停用服务…")) {
                            Task { await model.disableServices() }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            statePill(model.helperStatus,
                                      success: helperReady)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuIndicator(.hidden).buttonStyle(.plain)
                    .fixedSize()
                }

                settingsRow(L10n.text("加密备份与迁移"),
                    subtitle: L10n.text("配置、证书材料和历史版本的加密备份与预览恢复"),
                    symbol: "lock.doc") {
                    Button(L10n.text("备份与恢复…")) { model.quickAccess.openMainWindow(); model.showingProfileBackup = true }
                        .buttonStyle(ReferenceSecondaryButton()).disabled(!model.canUseProfileBackup)
                }
                settingsRow(L10n.text("配置列表备份"),
                    subtitle: model.profileIndexBackupStatus,
                    symbol: "externaldrive.badge.timemachine") {
                    Button(L10n.text("检查与恢复…")) { Task { await model.inspectProfileIndex() } }
                        .buttonStyle(ReferenceSecondaryButton())
                        .disabled(model.busy || model.profileTransferInProgress || model.maintenanceInProgress)
                }

                settingsRow(L10n.text("安全恢复"),
                    subtitle: L10n.text("遇到网络问题时，可尝试恢复残留的网络设置"),
                    symbol: "globe") {
                    Button(L10n.text("开始恢复")) {
                        Task { await model.retryNetworkRecovery() }
                    }
                    .buttonStyle(ReferenceSecondaryButton())
                    .controlSize(.regular)
                    .disabled(model.connected || model.connecting)
                }

                }
                .glassCard(cornerRadius: 16)

                settingsSection(L10n.text("应用"))
                VStack(spacing: 0) {
                settingsRow(L10n.text("智能连接与状态通知"),
                    subtitle: model.smartConnection.status,
                    symbol: "bolt.shield") {
                    Button(L10n.text("配置…")) { model.quickAccess.openMainWindow(); model.showingSmartConnection = true }.buttonStyle(ReferenceSecondaryButton())
                }
                settingsRow(L10n.text("应用更新"),
                    subtitle: L10n.format("当前版本：{0} (Build {1})", [String(describing: version), String(describing: build)]),
                    symbol: "arrow.triangle.2.circlepath") {
                    Menu {
                        Button(L10n.text("检查更新")) {
                            Task { await model.checkForUpdates() }
                        }
                        Button(L10n.text("下载已验证的更新包…")) {
                            Task { await model.downloadVerifiedUpdate() }
                        }
                        .disabled(model.availableInstaller == nil || model.busy)
                        Button(L10n.text("查看发布说明…")) { model.viewReleasePage() }
                            .disabled(model.availableReleasePage == nil)
                    } label: {
                        HStack(spacing: 8) {
                            statePill(model.availableInstaller == nil ?
                                      L10n.text("检查更新") : L10n.text("可下载更新"))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuIndicator(.hidden).buttonStyle(.plain)
                    .fixedSize()
                }

                settingsRow(L10n.text("关于"),
                    subtitle: "VPN Navigator · \(version) (Build \(build)) · \(BuildChannel.label)",
                    symbol: "info.circle.fill") {
                    Menu {
                        Text("macOS 13+")
                        Text(L10n.text("PF 断线保护为实验性功能"))
                        Text(L10n.text("支持 IPv4／IPv6 分流；需服务器提供对应隧道"))
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 24, height: 30)
                            .foregroundStyle(.secondary)
                    }
                    .menuIndicator(.hidden).buttonStyle(.plain)
                    .fixedSize()
                }
                }
                .glassCard(cornerRadius: 16)

                settingsSection(L10n.text("使用与排查"))
                VStack(spacing: 0) {
                    settingsRow(L10n.text("连接偏好"), subtitle: L10n.text("连接超时、重连与登录启动"), symbol: "slider.horizontal.3") {
                        Button(L10n.text("设置…")) { model.showingPreferences = true }.buttonStyle(ReferenceSecondaryButton())
                    }
                    settingsRow(L10n.text("诊断报告"), subtitle: L10n.text("查看脱敏会话事件并导出支持报告"), symbol: "doc.text.magnifyingglass") {
                        Button(L10n.text("查看…")) { model.showingDiagnostics = true }.buttonStyle(ReferenceSecondaryButton())
                    }
                    settingsRow(L10n.text("连接历史"), subtitle: L10n.text("采集速率、会话时间线及本机记录保留期限"), symbol: "clock.arrow.circlepath") {
                        Button(L10n.text("查看…")) { model.showingConnectionHistory = true }.buttonStyle(ReferenceSecondaryButton())
                    }
                    settingsRow(L10n.text("升级与卸载"), subtitle: L10n.text("准备安装更新或安全移除应用"), symbol: "shippingbox") {
                        Button(L10n.text("准备…")) { model.showingMaintenance = true }.buttonStyle(ReferenceSecondaryButton())
                    }
                    settingsRow(L10n.text("安装检查"), subtitle: L10n.text("检查引擎、后台助手和配置是否就绪"), symbol: "checklist") {
                        Button(L10n.text("打开…")) { model.showingSetup = true }.buttonStyle(ReferenceSecondaryButton())
                    }
                }.glassCard(cornerRadius: 16)

                Label(L10n.text("系统操作可能需要管理员授权。"), systemImage: "lock.shield")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding(.horizontal, GlassLayout.pageInset)
            .padding(.top, GlassLayout.pageTop)
            .padding(.bottom, 20)
            .frame(maxWidth: 1060, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    private func settingsSection(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 4).padding(.top, 4)
    }

    private func statePill(_ text: String, success: Bool = false) -> some View {
        HStack(spacing: 5) {
            if success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
            }
            Text(text)
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(success ? Color.green : Color.secondary)
        .padding(.horizontal, 11)
        .frame(height: 25)
        .background(success ? Color.green.opacity(0.11) :
                    GlassSurface.panel.opacity(0.45),
                    in: Capsule())
    }

    private func settingsRow<Actions: View>(
        _ title: String, subtitle: String, symbol: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .center, spacing: 13) {
            GlassIcon(symbol: symbol, size: 46)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            actions()
        }
        .padding(.horizontal, GlassLayout.pageInset)
        .frame(minHeight: 88)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if title == L10n.text("特权助手") || title == L10n.text("应用更新") {
                Rectangle().fill(GlassPalette.ink.opacity(0.06))
                    .frame(height: 0.75).padding(.leading, 79).padding(.trailing, 20)
            }
        }
    }
}

private enum ProfileInspectorTab: String, CaseIterable, Identifiable {
    case details = "基本信息"
    case advanced = "高级设置"
    case route = "路由策略"
    case history = "历史版本"
    var id: String { rawValue }
}

struct ProfileDetail: View {
    @EnvironmentObject private var model: AppModel
    let profile: VPNProfile
    var isVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var inspectorSelection
    private enum EditorField: Hashable { case name, notes }
    @FocusState private var focusedField: EditorField?
    @State private var tab: ProfileInspectorTab = .details
    @State private var draftName = ""
    @State private var draftGroup = ""
    @State private var draftNotes = ""
    @State private var editActionHovered = false
    @State private var editingCustomGroup = false
    @State private var customGroupDraft = ""
    @State private var editorText = ""
    @State private var showingEditor = false
    @State private var confirmDelete = false
    @State private var history: [ProfileRevision] = []

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.height >= 510 {
                inspectorContent
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    inspectorContent
                }
            }
        }
        .alert(L10n.text("自定义类别"), isPresented: $editingCustomGroup) {
            TextField(L10n.text("类别名称"), text: $customGroupDraft)
            Button(L10n.text("确定")) { draftGroup = customGroupDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
                .disabled(customGroupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || customGroupDraft.trimmingCharacters(in: .whitespacesAndNewlines).count > 48)
            Button(L10n.text("取消"), role: .cancel) { }
        } message: {
            Text(L10n.text("输入最多 48 字的类别名称。保存配置后，可在其它配置中复用。"))
        }
        .confirmationDialog(L10n.text("确定要删除此配置？"), isPresented: $confirmDelete) {
            Button(L10n.text("删除配置"), role: .destructive) {
                Task { await model.deleteProfile(profile.id) }
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("会删除本机存储的配置及相应凭据，且无法撤销。"))
        }
        .sheet(isPresented: $showingEditor) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("编辑 OpenVPN 配置"))
                    .font(.system(size: 20, weight: .bold))
                Text(L10n.text("文件可能含有私钥。危险脚本和不受支持的配置不能保存；修改在重新连接后生效。"))
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $editorText)
                    .font(.system(.body, design: .monospaced))
                    .padding(5)
                    .glassCard(cornerRadius: 12)
                HStack {
                    Button(L10n.text("取消")) {
                        editorText = ""
                        showingEditor = false
                    }
                    Spacer()
                    Button(L10n.text("保存新版本")) {
                        Task {
                            if await model.saveSource(for: profile, text: editorText) {
                                editorText = ""
                                history = await model.revisions(for: profile)
                                showingEditor = false
                            }
                        }
                    }
                    .buttonStyle(ReferencePrimaryButton())
                }
            }
            .padding(24)
            .frame(minWidth: 690, minHeight: 505)
            .background(GlassAtmosphere())
        }
        .onChange(of: isVisible) { visible in if !visible { focusedField = nil } }
        .onAppear {
            draftName = profile.name
            draftGroup = profile.group
            draftNotes = profile.notes
            Task { history = await model.revisions(for: profile) }
        }
    }

    private var inspectorContent: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 13) {
                    BrandMark(size: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.system(size: 28, weight: .bold))
                        Text(profile.sourceFilename)
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        let favorite = !profile.isFavorite
                        Task { await model.setProfileFavorite(favorite, for: profile.id) }
                    } label: {
                        Image(systemName: profile.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(profile.isFavorite ? .orange : .secondary)
                    }
                    .buttonStyle(ReferenceSecondaryButton())
                    .help(profile.isFavorite ? L10n.text("取消收藏") : L10n.text("收藏此配置"))
                    .accessibilityLabel(profile.isFavorite ? L10n.text("取消收藏此配置") : L10n.text("收藏此配置"))
                    .accessibilityValue(profile.isFavorite ? L10n.text("已收藏") : L10n.text("未收藏"))
                    .disabled(!model.canEditProfileMetadata(profile.id))
                    Menu {
                        Button(L10n.text("配置健康检查…")) { model.showProfileHealth(profile.id) }
                            .disabled(model.profileTransferInProgress || model.maintenanceInProgress)
                        Button(L10n.text("更新配置文件…")) { model.showProfileHealth(profile.id, updating: true) }
                            .disabled(model.profileTransferInProgress || model.maintenanceInProgress)
                        Divider()
                        Button(L10n.text("自定义分流规则…")) { model.customRuleEditorProfile = profile }
                            .disabled(model.profileTransferInProgress || model.maintenanceInProgress)
                        Button(L10n.text("导出可迁移配置…")) { Task { await model.exportProfile(for: profile.id) } }
                            .disabled(model.profileTransferInProgress || model.maintenanceInProgress)
                        Button(L10n.text("导出路由预览…")) { Task { await model.exportProfile(kind: .routePreview, for: profile.id) } }
                            .disabled(model.profileTransferInProgress || model.maintenanceInProgress || (profile.mode == .chinaDirect && model.rules == nil))
                        Button(L10n.text("删除配置…"), role: .destructive) {
                            confirmDelete = true
                        }.disabled(!model.canDeleteProfile(profile.id))
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 22, height: 22)
                            .foregroundStyle(.secondary)
                    }
                    .menuIndicator(.hidden)
                    .accessibilityLabel(L10n.text("配置操作")).accessibilityValue(profile.name)
                    .fixedSize()
                }
                HStack(spacing: 4) {
                    ForEach(ProfileInspectorTab.allCases) { section in
                        Button {
                            tab = section
                        } label: {
                            Text(L10n.text(section.rawValue))
                                .font(.system(size: 14, weight: tab == section ?
                                              .semibold : .regular))
                                .foregroundStyle(tab == section ?
                                                 Color.white : Color.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background {
                                    if tab == section {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(GlassPalette.blue)
                                            .matchedGeometryEffect(id: "inspector-selection", in: inspectorSelection)
                                    }
                                }
                        }
                        .buttonStyle(ReferenceQuietButton())
                        .accessibilityAddTraits(tab == section ? .isSelected : [])
                        .accessibilityValue(tab == section ? L10n.text("已选择") : L10n.text("未选择"))
                    }
                }
                .referenceSegments()
                .animation(GlassMotion.selection(reduceMotion), value: tab)

                Group {
                    switch tab {
                    case .details: metadata
                    case .advanced: advanced
                    case .route: routeMode
                    case .history: revisions
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Button { model.showProfileHealth(profile.id) } label: {
                        Label(model.profileHealth.reports[profile.id]?.title ?? L10n.text("检查配置"), systemImage: "checkmark.shield")
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("保存更改")) {
                        Task {
                            await model.updateMetadata(name: draftName, group: draftGroup,
                                                       notes: draftNotes, favorite: profile.isFavorite, for: profile.id)
                        }
                    }
                    .buttonStyle(ReferencePrimaryButton()).disabled(!model.canEditProfileMetadata(profile.id))
                    Button(model.profileExportInProgress ? L10n.text("导出中…") : L10n.text("导出配置…")) { Task { await model.exportProfile(for: profile.id) } }
                        .buttonStyle(ReferenceSecondaryButton())
                        .disabled(model.profileTransferInProgress || model.maintenanceInProgress)
                }
                .font(.system(size: 14))
                .padding(.top, 3)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: 480, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            editorRow(L10n.text("名称")) {
                TextField(L10n.text("配置名称"), text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .name)
                    .referenceInput(focused: focusedField == .name)
            }
            editorRow(L10n.text("类别")) {
                Menu {
                    ForEach(ProfileLibraryQuery.groupChoices(model.profiles, current: draftGroup), id: \.self) { group in
                        Button(group) { draftGroup = group }
                    }
                    Divider()
                    Button(L10n.text("自定义类别…")) { customGroupDraft = draftGroup; editingCustomGroup = true }
                } label: {
                    HStack {
                        Text(draftGroup.isEmpty ? L10n.text("选择类别") : draftGroup)
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                    }
                    .referenceInput()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            editorRow(L10n.text("源文件")) {
                Label(profile.sourceFilename, systemImage: "doc.text.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(GlassPalette.blue)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .referenceInput()
                Button {
                    Task {
                        if let text = await model.editSource(for: profile) {
                            editorText = text
                            showingEditor = true
                        }
                    }
                } label: {
                    Text(L10n.text("编辑文件…"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(GlassPalette.ink)
                        .frame(width: 94, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(editActionHovered ? 0.46 : 0.30)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.75)
                            .allowsHitTesting(false))
                }
                .buttonStyle(.plain)
                .onHover { editActionHovered = $0 }
                .animation(GlassMotion.feedback(reduceMotion), value: editActionHovered)
                .fixedSize()
                .layoutPriority(1)
                .disabled(model.connected || model.connecting)
            }
            editorRow(L10n.text("备注")) {
                TextField(L10n.text("添加备注信息…"), text: $draftNotes, axis: .vertical)
                    .lineLimit(2...2)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .notes)
                    .referenceInput(height: 58, focused: focusedField == .notes)
            }
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent(L10n.text("创建时间")) {
                    Text(profile.importedAt, format: .dateTime.year().month().day().hour().minute())
                }
                LabeledContent(L10n.text("修改时间")) {
                    if let editedAt = history.first?.createdAt {
                        Text(editedAt, format: .dateTime.year().month().day().hour().minute())
                    } else {
                        Text(L10n.text("无编辑记录"))
                    }
                }
                LabeledContent(L10n.text("文件大小"), value: model.profileSizes[profile.id].map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                LabeledContent(L10n.text("配置类型"), value: "OpenVPN")
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.top, 3)
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.text("安全编辑"), systemImage: "curlybraces")
                .font(.system(size: 18, weight: .semibold))
            Text(L10n.text("保留原始 .ovpn 文件及版本快照，不会执行导入文件中的脚本。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Button(L10n.text("编辑 .ovpn 文件…")) {
                Task {
                    if let text = await model.editSource(for: profile) {
                        editorText = text
                        showingEditor = true
                    }
                }
            }
            .buttonStyle(ReferencePrimaryButton())
            .disabled(model.connected || model.connecting || model.stopping)
            LabeledContent(L10n.text("源文件"), value: profile.sourceFilename)
            LabeledContent(L10n.text("保存位置"), value: L10n.text("本机私有配置仓库"))
            Text(L10n.text("只有断开连接后才能更改或恢复配置。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(17)
        .glassCard(cornerRadius: 14)
    }

    private var routeMode: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("所选配置的默认路由策略"))
                .font(.system(size: 16, weight: .medium))
            ForEach(RoutingMode.allCases) { mode in
                Button { Task { await model.setMode(mode, for: profile.id) } } label: {
                    HStack {
                        Image(systemName: model.displayedRoutingMode(for: profile.id) == mode ? "largecircle.fill.circle" : "circle")
                        Text(mode.title)
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!model.canSetRoutingMode(mode, for: profile.id))
            }
            if model.connected, model.activeProfileID == profile.id {
                Text(model.routingModeStatus).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(L10n.text("规则路由使用中国 IPv4 及 APNIC 中国 IPv6 注册前缀。全局与规则可在线切换；IPv6 需服务器分配隧道地址及有效规则缓存。"))
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(17)
        .glassCard(cornerRadius: 14)
    }

    private var revisions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("已保存的配置版本"))
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(L10n.text("刷新历史")) {
                    Task { history = await model.revisions(for: profile) }
                }
                .controlSize(.small)
            }
            if history.isEmpty {
                Label(L10n.text("暂无历史版本"), systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.prefix(10)) { revision in
                    HStack {
                        Image(systemName: "clock").foregroundStyle(.blue)
                        Text(revision.createdAt, format: .dateTime.year().month().day().hour().minute())
                        Spacer()
                        Button(L10n.text("恢复此版本")) {
                            Task {
                                if await model.restoreSource(for: profile, revision: revision.filename) {
                                    history = await model.revisions(for: profile)
                                }
                            }
                        }
                        .disabled(model.connected || model.connecting)
                    }
                    .font(.system(size: 14))
                    Divider().opacity(0.3)
                }
            }
            Text(L10n.text("版本保存在本机，不会上传至云端。"))
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard(cornerRadius: 14)
    }

    private func editorRow<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: L10n.language == .english ? 88 : 66, alignment: .leading)
            content()
        }
    }
}

