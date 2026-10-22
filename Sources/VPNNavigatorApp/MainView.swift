import SwiftUI
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
        case .overview: return "连接总览"
        case .profiles: return "配置文件"
        case .routing: return "路由与规则"
        case .diagnostics: return "网络诊断"
        case .settings: return "设置与维护"
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

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: WorkspaceTab = .overview
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sidebarSelection

    /// The UI snapshot argument selects a real application page for macOS
    /// screenshot checks. It never changes connectivity or network state.
    init() {
        if let value = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--vpnnav-ui-tab=") })?
            .split(separator: "=", maxSplits: 1).last,
           let initialTab = WorkspaceTab(rawValue: String(value)) {
            _tab = State(initialValue: initialTab)
        }
    }

    var body: some View {
        ZStack {
            GlassAtmosphere()
            HStack(spacing: 0) {
                sidebar.frame(width: 228)
                Rectangle().fill(Color.white.opacity(0.24)).frame(width: 1)
                VStack(spacing: 0) {
                    Group {
                        switch tab {
                        case .overview: ConnectionOverview()
                        case .profiles: ProfileLibrary(onImport: {
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
                        Label("松开以导入 .ovpn 配置", systemImage: "square.and.arrow.down")
                            .font(.system(size: 18, weight: .semibold)).padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }.allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .onAppear {
            model.quickAccess.openMainWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            if ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-quick-access-snapshot") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.quickAccess.show() }
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
        .sheet(isPresented: $model.showingAccountCredentials) { AccountCredentialsView().environmentObject(model) }
        .sheet(item: $model.authenticationChallenge) { challenge in
            AuthenticationChallengeView(challenge: challenge).id(challenge.id).environmentObject(model)
        }
        .sheet(isPresented: $model.showingMaintenance) { MaintenanceAssistantView().environmentObject(model) }
        .sheet(isPresented: $model.showingSetup) { SetupAssistantView().environmentObject(model) }
        .sheet(isPresented: $model.showingPreferences) { ClientPreferencesView().environmentObject(model) }
        .sheet(isPresented: $model.showingDiagnostics) { DiagnosticHistoryView().environmentObject(model) }
        .sheet(isPresented: $model.showingImportReport) {
            if model.reviewingIncomingProfiles { ProfileOpenReviewView().environmentObject(model) }
            else { ProfileImportReportView().environmentObject(model) }
        }
        .onChange(of: model.showingImportReport) { shown in if shown { tab = .profiles } }
        .alert("VPN Navigator", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("确定") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN Navigator").font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Text("网络连接控制台").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.top, 42)
            .padding(.bottom, 30)

            Text("工作区")
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
                .accessibilityAddTraits(tab == item ? .isSelected : [])
                .padding(.horizontal, 15)
                .padding(.bottom, 5)
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 15) {
                Button { model.profilePickerPresented = true } label: {
                    Label("导入配置", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ReferenceSecondaryButton())
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.canChooseProfileFiles)
                Text(model.profileDropLoading ? "正在接收文件…" : "可将 .ovpn 文件拖入窗口")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !model.incomingProfiles.isEmpty && !model.reviewingIncomingProfiles {
                    Text("待处理：\(model.incomingProfiles.urls.count) 个配置")
                        .font(.system(size: 11)).foregroundStyle(GlassPalette.blue)
                }
                Rectangle().fill(GlassPalette.ink.opacity(0.07)).frame(height: 0.75)
                HStack(spacing: 8) {
                    Circle().fill(model.connected ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(model.connected ? "VPN 已连接" : model.connecting ? "正在连接…" : "VPN 未连接")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text("\(model.profiles.count) 个配置")
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
        model.connected ? "已连接" : model.firewallRecoveryRequired && !model.connecting ? "网络保护待处理" : model.stopping ? "正在断开" : model.connecting ? "正在连接" : hasError ? "连接需检查" : "未连接"
    }
    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "— MB" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkspaceHeading(title: "连接总览", subtitle: "清晰掌控当前 VPN 状态与网络策略", symbol: "globe.americas.fill")
                .padding(.bottom, 4)
            HStack(spacing: 12) {
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button {
                        guard model.selected != nil || model.connected else {
                            model.message = "请先导入并选择一个 .ovpn 配置文件。"
                            return
                        }
                        Task {
                            if model.connected || model.connecting || model.firewallRecoveryRequired { await model.disconnect() }
                            else { await model.connectSelected() }
                        }
                    } label: { ReferencePowerOrb() }
                    .buttonStyle(ReferenceQuietButton(cornerRadius: 110, hoverOpacity: 0.04))
                    .disabled(model.stopping || (model.busy && !model.connecting && !model.connected && !model.firewallRecoveryRequired))
                    .accessibilityLabel(model.connected ? "断开 VPN" : model.connecting ? "取消连接" : "连接 VPN")
                    Text(statusTitle)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(model.connected ? Color.green : hasError ? Color.orange : GlassPalette.blue)
                    Text(model.connected ? "安全连接已建立" : model.connecting ? "点击上方按钮取消连接" : model.firewallRecoveryRequired ? "点击上方按钮解除断线保护" : "点击上方按钮开始连接")
                        .font(.system(size: 16))
                        .foregroundStyle(model.connected ? Color.green : GlassPalette.ink.opacity(0.6))
                    if model.connected && model.activeProfileID != model.selectedID && model.selectedID != nil {
                        Button("切换到所选配置") { confirmSwitch = true }
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
                            Text("快速连接").fontWeight(.semibold)
                            Spacer()
                            Button { showingCredentials = true } label: {
                                Image(systemName: "key.horizontal")
                                    .font(.system(size: 14))
                                    .foregroundStyle(GlassPalette.ink.opacity(0.45))
                            }
                            .buttonStyle(.plain)
                            .help("身份验证")
                            .popover(isPresented: $showingCredentials) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("身份验证").font(.headline)
                                    TextField("用户名", text: $model.username).textFieldStyle(.plain).referenceInput()
                                    SecureField("密码", text: $model.password).textFieldStyle(.plain).referenceInput()
                                    Toggle("保存在钥匙串", isOn: $model.rememberCredentials)
                                }.padding(20).frame(width: 290)
                            }
                        }
                        .font(.system(size: 18))
                        quickRow("配置文件") {
                            Menu {
                                ForEach(model.profiles) { profile in
                                    Button(profile.name) { model.selectedID = profile.id }
                                }
                            } label: {
                                selectionField(model.selected?.name ?? "请选择配置", stepper: true)
                            }
                                                        .menuIndicator(.hidden)
                            .buttonStyle(.plain)
                            .disabled(model.profiles.isEmpty || model.busy)
                        }
                        quickRow("路由模式") {
                            Menu {
                                ForEach(RoutingMode.allCases) { mode in
                                    Button(mode.rawValue) { Task { await model.setMode(mode) } }
                                }
                            } label: {
                                selectionField(model.selected?.mode.rawValue ?? "Original", stepper: false)
                            }
                                                        .menuIndicator(.hidden)
                            .buttonStyle(.plain)
                            .disabled(model.selected == nil || model.busy || model.connected || model.connecting)
                        }
                        quickRow("源文件") {
                            Text(model.selected?.sourceFilename ?? "未选择配置")
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
                            Text(model.activeProfile?.name ?? model.selected?.name ?? "尚未选择配置")
                                .font(.system(size: 15, weight: .medium)).lineLimit(1)
                            Text(model.activeProfile?.sourceFilename ?? model.selected?.sourceFilename ?? "等待导入 .ovpn 文件")
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
            HStack(spacing: 12) {
                statistic("累计接收", symbol: "arrow.down.circle", value: bytes(model.traffic?.receivedBytes), samples: model.receiveTrend.samples)
                    .frame(width: 188)
                statistic("累计发送", symbol: "arrow.up.circle", value: bytes(model.traffic?.sentBytes), samples: model.sendTrend.samples)
                    .frame(width: 188)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                        .frame(width: 54, height: 54)
                        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("连接保护").font(.system(size: 18, weight: .semibold))
                        Label(model.firewallActive ? "PF 断线保护已接入" : "受管连接异常时停止会话", systemImage: model.firewallActive ? "checkmark.circle.fill" : "info.circle")
                            .font(.system(size: 12)).foregroundStyle(.green)
                        Text(model.firewallActive ? "实验性保护，完整真机防泄漏验收待完成。" : "可在连接偏好中启用实验性断线保护。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 158, alignment: .topLeading)
                .glassCard(cornerRadius: 17)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GlassLayout.pageInset)
        .padding(.top, GlassLayout.pageTop)
        .padding(.bottom, 16)
        .confirmationDialog("切换 VPN 配置？", isPresented: $confirmSwitch) {
            Button("断开当前连接并切换") { Task { await model.switchToSelected() } }
            Button("取消", role: .cancel) { }
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
    private func statistic(_ title: String, symbol: String, value: String, samples: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(GlassPalette.blue)
                Text(title).font(.system(size: 16)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 30, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
            TrafficSparkline(samples: samples).frame(height: 33)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 158)
        .glassCard(cornerRadius: 17)
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

private struct ProfileLibrary: View {
    @EnvironmentObject private var model: AppModel
    let onImport: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [VPNProfile] {
        model.profiles.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
                $0.sourceFilename.localizedCaseInsensitiveContains(query) ||
                $0.group.localizedCaseInsensitiveContains(query)
        }.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            WorkspaceHeading(title: "配置文件",
                subtitle: "管理和编辑 VPN 配置文件",
                symbol: "square.stack.3d.up.fill")
                .padding(.bottom, 4)

            HStack(spacing: 10) {
                HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
                TextField("搜索配置文件…", text: $query)
                    .focused($searchFocused)
                    .font(.system(size: 16))
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
                .referenceInput(height: 42, focused: searchFocused)
                Button(action: onImport) {
                    Label("导入配置", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(height: 26)
                }
                .buttonStyle(ReferencePrimaryButton())
                .tint(GlassPalette.blue)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("全部配置 (\(filtered.count))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 3)

                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(filtered) { profile in
                                Button { searchFocused = false; model.selectedID = profile.id } label: {
                                    HStack(spacing: 9) {
                                        GlassIcon(symbol: "globe",
                                                  color: profile.isFavorite ?
                                                    GlassPalette.blue : GlassPalette.cyan,
                                                  size: 40)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(profile.name)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(profile.sourceFilename)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer(minLength: 3)
                                        if profile.isFavorite {
                                            Image(systemName: "star.fill")
                                                .foregroundStyle(.orange)
                                                .font(.system(size: 14))
                                        } else {
                                            Circle()
                                                .fill(Color.secondary.opacity(0.30))
                                                .frame(width: 7, height: 7)
                                        }
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        model.selectedID == profile.id ?
                                          GlassPalette.blue.opacity(0.17) :
                                          Color.white.opacity(0.035),
                                        in: RoundedRectangle(cornerRadius: 11))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 11)
                                            .strokeBorder(model.selectedID == profile.id ?
                                                GlassPalette.blue.opacity(0.18) : .clear,
                                                lineWidth: 1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(ReferenceQuietButton(cornerRadius: 11))
                                .accessibilityAddTraits(
                                    model.selectedID == profile.id ? .isSelected : [])
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Label("没有匹配的配置", systemImage: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(width: 230)
                .frame(maxHeight: .infinity, alignment: .top)
                .glassCard(cornerRadius: 15)

                Group {
                    if let profile = model.selected {
                        ProfileDetail(profile: profile).id(profile.id)
                    } else {
                        VStack(spacing: 10) {
                            GlassIcon(symbol: "square.stack.3d.up", size: 45)
                            Text("尚未选择配置文件").font(.headline)
                            Text("点击右上角「导入配置」以添加 .ovpn 文件")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassCard(cornerRadius: 16)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, GlassLayout.pageInset)
        .padding(.top, GlassLayout.pageTop)
        .padding(.bottom, 18)
    }
}

private struct RoutingWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @State private var snapshotToRestore: RuleSnapshot?
    @State private var importingRules = false

    private func title(for mode: RoutingMode) -> String {
        switch mode {
        case .original: return "Original"
        case .fullVPN: return "Full VPN"
        case .chinaDirect: return "中国 IPv4 直连"
        }
    }
    private func subtitle(for mode: RoutingMode) -> String {
        switch mode {
        case .original: return "不修改 VPN，保留原始网络连接"
        case .fullVPN: return "所有 IPv4 流量通过 VPN 连接"
        case .chinaDirect: return "仅中国 IPv4 流量直连，其他流量走 VPN"
        }
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceHeading(title: "路由与规则", subtitle: "管理 VPN 路由模式与中国 IPv4 规则", symbol: "point.3.connected.trianglepath.dotted")
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(GlassPalette.blue)
                Text("当前配置").foregroundStyle(.secondary)
                Text(model.selected?.name ?? "尚未选择").fontWeight(.medium)
                Spacer()
                Text("切换模式在下次连接时生效").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.vertical, 4)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("路由模式").font(.system(size: 20, weight: .semibold))
                    ForEach(RoutingMode.allCases) { mode in routeOption(mode) }
                    Spacer(minLength: 8)
                    Text("路由策略按配置保存，连接期间无法更改。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(width: max(280, (geometry.size.width - 62) * 0.43))
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .glassCard(cornerRadius: 18)
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("中国 IPv4 规则").font(.system(size: 20, weight: .semibold))
                        HStack(alignment: .top, spacing: 16) {
                            GlassIcon(symbol: "globe.asia.australia", size: 67)
                            VStack(alignment: .leading, spacing: 16) {
                                ruleDetail("规则版本", model.rulesUpdatedAt.map { $0.formatted(.dateTime.year().month().day()) } ?? "未下载")
                                ruleDetail("规则来源", "chnroutes2")
                                ruleDetail("规则数量", model.rules.map { "\($0.routes.count) 条" } ?? "未下载")
                                ruleDetail("最后更新", model.rulesUpdatedAt.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "尚无缓存")
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 12) {
                            Button { Task { await model.refreshRules() } } label: {
                                Text(model.busy ? "更新中…" : "更新规则").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ReferencePrimaryButton()).disabled(model.busy)
                            Menu {
                                Button("导入规则文件…") { importingRules = true }
                                Divider()
                                ForEach(model.ruleSnapshots) { saved in
                                    Button(saved.savedAt.formatted(.dateTime.year().month().day().hour().minute())) { snapshotToRestore = saved }
                                }
                            } label: { Text("历史与导入").frame(maxWidth: .infinity) }
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
                                Text("IPv6 规则（预览）").font(.system(size: 16, weight: .semibold))
                                Spacer(minLength: 0)
                                Text("预览").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.gray.opacity(0.09), in: Capsule())
                            }
                            Text(model.ipv6Preview.map { "\($0.routes.count) 个 APNIC 前缀 · 仅供查看" } ?? "仅用于查看，不修改系统 IPv6 路由。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Button { Task { await model.updateIPv6Preview() } } label: {
                            Image(systemName: "arrow.clockwise").foregroundStyle(GlassPalette.blue)
                        }.buttonStyle(.plain).disabled(model.busy).help("刷新 IPv6 预览")
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
        .fileImporter(isPresented: $importingRules, allowedContentTypes: [.plainText]) { result in
            if case .success(let url) = result { Task { await model.importRules(url) } }
        }
        .confirmationDialog("恢复旧版 IPv4 规则？", isPresented: Binding(
            get: { snapshotToRestore != nil }, set: { if !$0 { snapshotToRestore = nil } }
        )) {
            if let snapshot = snapshotToRestore {
                Button("确认恢复历史快照") {
                    Task { await model.restoreRuleSnapshot(snapshot.id) }
                    snapshotToRestore = nil
                }
            }
            Button("取消", role: .cancel) { snapshotToRestore = nil }
        } message: { Text("恢复会替换当前规则，已有受管连接的安全限制仍然适用。") }
        }
    }

    private func routeOption(_ mode: RoutingMode) -> some View {
        let selected = model.selected?.mode ?? .original
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
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
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
        .disabled(model.selected == nil || model.busy ||
                  model.connected || model.connecting)
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
    private var helperReady: Bool { model.helperStatus == "已启用" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                WorkspaceHeading(title: "设置与维护",
                    subtitle: "管理系统服务、应用更新与网络恢复", symbol: "gearshape")
                    .padding(.bottom, 10)

                settingsSection("系统与网络")
                VStack(spacing: 0) {

                settingsRow("特权助手",
                    subtitle: "管理系统使用此配置所需的特权助手",
                    symbol: "shield.lefthalf.filled") {
                    Menu {
                        Button("启用服务…") { model.requestHelper() }
                        Button("停用服务…") {
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

                settingsRow("安全恢复",
                    subtitle: "遇到网络问题时，可尝试恢复残留的网络设置",
                    symbol: "globe") {
                    Button("开始恢复") {
                        Task { await model.retryNetworkRecovery() }
                    }
                    .buttonStyle(ReferenceSecondaryButton())
                    .controlSize(.regular)
                    .disabled(model.connected || model.connecting)
                }

                }
                .glassCard(cornerRadius: 16)

                settingsSection("应用")
                VStack(spacing: 0) {
                settingsRow("应用更新",
                    subtitle: "当前版本：\(version) (Build \(build))",
                    symbol: "arrow.triangle.2.circlepath") {
                    Menu {
                        Button("检查更新") {
                            Task { await model.checkForUpdates() }
                        }
                        Button("下载已验证的更新包…") {
                            Task { await model.downloadVerifiedUpdate() }
                        }
                        .disabled(model.availableInstaller == nil || model.busy)
                        Button("查看发布说明…") { model.viewReleasePage() }
                            .disabled(model.availableReleasePage == nil)
                    } label: {
                        HStack(spacing: 8) {
                            statePill(model.availableInstaller == nil ?
                                      "检查更新" : "可下载更新")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuIndicator(.hidden).buttonStyle(.plain)
                    .fixedSize()
                }

                settingsRow("关于",
                    subtitle: "VPN Navigator · \(version) (Build \(build)) · \(BuildChannel.label)",
                    symbol: "info.circle.fill") {
                    Menu {
                        Text("macOS 13+")
                        Text("PF 断线保护为实验性功能")
                        Text("IPv6 分流尚未实现")
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

                settingsSection("使用与排查")
                VStack(spacing: 0) {
                    settingsRow("连接偏好", subtitle: "连接超时、重连与登录启动", symbol: "slider.horizontal.3") {
                        Button("设置…") { model.showingPreferences = true }.buttonStyle(ReferenceSecondaryButton())
                    }
                    settingsRow("诊断报告", subtitle: "查看脱敏会话事件并导出支持报告", symbol: "doc.text.magnifyingglass") {
                        Button("查看…") { model.showingDiagnostics = true }.buttonStyle(ReferenceSecondaryButton())
                    }
                    settingsRow("升级与卸载", subtitle: "准备安装更新或安全移除应用", symbol: "shippingbox") {
                        Button("准备…") { model.showingMaintenance = true }.buttonStyle(ReferenceSecondaryButton())
                    }
                    settingsRow("安装检查", subtitle: "检查引擎、后台助手和配置是否就绪", symbol: "checklist") {
                        Button("打开…") { model.showingSetup = true }.buttonStyle(ReferenceSecondaryButton())
                    }
                }.glassCard(cornerRadius: 16)

                Label("系统操作可能需要管理员授权。", systemImage: "lock.shield")
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
            if title == "特权助手" || title == "应用更新" {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var inspectorSelection
    private enum EditorField: Hashable { case name, notes }
    @FocusState private var focusedField: EditorField?
    @State private var tab: ProfileInspectorTab = .details
    @State private var draftName = ""
    @State private var draftGroup = ""
    @State private var draftNotes = ""
    @State private var draftFavorite = false
    @State private var editActionHovered = false
    @State private var editingCustomGroup = false
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
        .alert("自定义类别", isPresented: $editingCustomGroup) {
            TextField("类别名称", text: $draftGroup)
            Button("确定") { }
            Button("取消", role: .cancel) { }
        } message: {
            Text("输入此配置文件所属的类别名称。")
        }
        .confirmationDialog("确定要删除此配置？", isPresented: $confirmDelete) {
            Button("删除配置", role: .destructive) {
                Task { await model.deleteSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除本机存储的配置及相应凭据，且无法撤销。")
        }
        .sheet(isPresented: $showingEditor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("编辑 OpenVPN 配置")
                    .font(.system(size: 20, weight: .bold))
                Text("文件可能含有私钥。危险脚本和不受支持的配置不能保存；修改在重新连接后生效。")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $editorText)
                    .font(.system(.body, design: .monospaced))
                    .padding(5)
                    .glassCard(cornerRadius: 12)
                HStack {
                    Button("取消") {
                        editorText = ""
                        showingEditor = false
                    }
                    Spacer()
                    Button("保存新版本") {
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
        .onAppear {
            draftName = profile.name
            draftGroup = profile.group
            draftNotes = profile.notes
            draftFavorite = profile.isFavorite
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
                        draftFavorite.toggle()
                        Task {
                            await model.updateMetadata(
                                name: draftName, group: draftGroup,
                                notes: draftNotes, favorite: draftFavorite)
                        }
                    } label: {
                        Image(systemName: draftFavorite ? "star.fill" : "star")
                            .foregroundStyle(draftFavorite ? .orange : .secondary)
                    }
                    .buttonStyle(ReferenceSecondaryButton())
                    .help("收藏此配置")
                    Menu {
                        Button("导出可迁移配置…") { Task { await model.exportProfile() } }
                            .disabled(model.profileTransferInProgress || model.maintenanceInProgress)
                        Button("导出路由预览…") { Task { await model.exportProfile(kind: .routePreview) } }
                            .disabled(model.profileTransferInProgress || model.maintenanceInProgress || (profile.mode == .chinaDirect && model.rules == nil))
                        Button("删除配置…", role: .destructive) {
                            confirmDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 22, height: 22)
                            .foregroundStyle(.secondary)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                HStack(spacing: 4) {
                    ForEach(ProfileInspectorTab.allCases) { section in
                        Button {
                            tab = section
                        } label: {
                            Text(section.rawValue)
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
                        .buttonStyle(.plain)
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
                    Text("OpenVPN")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("保存更改") {
                        Task {
                            await model.updateMetadata(name: draftName, group: draftGroup,
                                                       notes: draftNotes, favorite: draftFavorite)
                        }
                    }
                    .buttonStyle(ReferencePrimaryButton())
                    Button(model.profileExportInProgress ? "导出中…" : "导出配置…") { Task { await model.exportProfile() } }
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
            editorRow("名称") {
                TextField("配置名称", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .name)
                    .referenceInput(focused: focusedField == .name)
            }
            editorRow("类别") {
                Menu {
                    ForEach(["个人", "工作", "家庭", "其他"], id: \.self) { group in
                        Button(group) { draftGroup = group }
                    }
                    Divider()
                    Button("自定义类别…") { editingCustomGroup = true }
                } label: {
                    HStack {
                        Text(draftGroup.isEmpty ? "选择类别" : draftGroup)
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
            editorRow("配置文件") {
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
                    Text("编辑文件…")
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
            editorRow("备注") {
                TextField("添加备注信息…", text: $draftNotes, axis: .vertical)
                    .lineLimit(2...2)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .notes)
                    .referenceInput(height: 58, focused: focusedField == .notes)
            }
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("创建时间") {
                    Text(profile.importedAt, format: .dateTime.year().month().day().hour().minute())
                }
                LabeledContent("修改时间") {
                    if let editedAt = history.first?.createdAt {
                        Text(editedAt, format: .dateTime.year().month().day().hour().minute())
                    } else {
                        Text("无编辑记录")
                    }
                }
                LabeledContent("文件大小", value: model.profileSizes[profile.id].map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                LabeledContent("配置类型", value: "OpenVPN")
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
            Label("安全编辑", systemImage: "curlybraces")
                .font(.system(size: 18, weight: .semibold))
            Text("保留原始 .ovpn 文件及版本快照，不会执行导入文件中的脚本。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Button("编辑 .ovpn 文件…") {
                Task {
                    if let text = await model.editSource(for: profile) {
                        editorText = text
                        showingEditor = true
                    }
                }
            }
            .buttonStyle(ReferencePrimaryButton())
            .disabled(model.connected || model.connecting || model.stopping)
            LabeledContent("源文件", value: profile.sourceFilename)
            LabeledContent("保存位置", value: "本机私有配置仓库")
            Text("只有断开连接后才能更改或恢复配置。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(17)
        .glassCard(cornerRadius: 14)
    }

    private var routeMode: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("所选配置的默认路由策略")
                .font(.system(size: 16, weight: .medium))
            Picker("模式", selection: Binding(
                get: { profile.mode },
                set: { value in Task { await model.setMode(value) } }
            )) {
                Text("遵循原始配置").tag(RoutingMode.original)
                Text("全局 VPN").tag(RoutingMode.fullVPN)
                Text("中国 IPv4 直连").tag(RoutingMode.chinaDirect)
            }
            .pickerStyle(.radioGroup)
            .disabled(model.busy || model.connected || model.connecting)
            Text("中国 IPv4 直连需要已经下载的网段规则；IPv6 地区分流未提供；断线保护可在连接偏好中启用。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(17)
        .glassCard(cornerRadius: 14)
    }

    private var revisions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已保存的配置版本")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("刷新历史") {
                    Task { history = await model.revisions(for: profile) }
                }
                .controlSize(.small)
            }
            if history.isEmpty {
                Label("暂无历史版本", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.prefix(10)) { revision in
                    HStack {
                        Image(systemName: "clock").foregroundStyle(.blue)
                        Text(revision.createdAt, format: .dateTime.year().month().day().hour().minute())
                        Spacer()
                        Button("恢复此版本") {
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
            Text("版本保存在本机，不会上传至云端。")
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
                .frame(width: 66, alignment: .leading)
            content()
        }
    }
}

