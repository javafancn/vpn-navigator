import SwiftUI
import VPNNavigatorCore

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
    @State private var tab: WorkspaceTab? = .overview
    @State private var importing = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 27, weight: .medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.blue, .cyan)
                        .frame(width: 42, height: 42)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPN Navigator").font(.system(size: 15, weight: .bold))
                        Text("网络连接控制台").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 18)
                List(selection: $tab) {
                    Section("工作空间") {
                        ForEach(WorkspaceTab.allCases) { item in
                            Label(item.title, systemImage: item.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.vertical, 5)
                                .tag(item)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                Divider().opacity(0.35)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Circle().fill(model.connected ? Color.green : Color.secondary.opacity(0.6))
                            .frame(width: 7, height: 7)
                        Text(model.connected ? "VPN 已连接" : model.connecting ? "正在连接" : "VPN 未连接")
                            .font(.caption.weight(.semibold))
                    }
                    Text(model.activeProfile?.name ?? "请选择配置文件")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("Alpha · macOS 13+")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(17).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 200)
            .background(.ultraThinMaterial)
        } detail: {
            ZStack {
                LinearGradient(
                    colors: [.blue.opacity(0.08), .clear, .cyan.opacity(0.035)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                switch tab ?? .overview {
                case .overview: ConnectionOverview()
                case .profiles: ProfileLibrary()
                case .routing: RoutingWorkspace()
                case .diagnostics: NetworkDiagnosticsView()
                case .settings: SystemSettingsPane()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: {
                    Label("导入 .ovpn", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help("导入 OpenVPN 配置文件")
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.init(filenameExtension: "ovpn")!],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task {
                    for url in urls { await model.importFile(url) }
                    tab = .profiles
                }
            case .failure(let error): model.message = error.localizedDescription
            }
        }
        .alert("VPN Navigator", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("确定") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

struct WorkspaceHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 27, weight: .bold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 7)
    }
}

struct VPNPanel<Content: View>: View {
    let title: String
    let symbol: String
    private let content: Content
    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(19)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19)
            .strokeBorder(.primary.opacity(0.07), lineWidth: 1))
    }
}

private struct ConnectionOverview: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmSwitch = false
    private var error: Bool { model.connectionStatus.hasPrefix("failed:") }
    private var statusTitle: String {
        if model.connected { return "已连接" }
        if model.connecting { return "正在建立安全连接" }
        if error { return "连接需要检查" }
        return "准备连接"
    }
    private var trafficText: String {
        guard let traffic = model.traffic else { return "—" }
        return ByteCountFormatter.string(fromByteCount:
            Int64(clamping: traffic.receivedBytes), countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WorkspaceHeading(title: "连接总览",
                    subtitle: "清晰掌控当前 VPN 状态与网络策略",
                    symbol: "network.badge.shield.half.filled")
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 13) {
                        Button {
                            Task {
                                if model.connected { await model.disconnect() }
                                else { await model.connectSelected() }
                            }
                        } label: {
                            Image(systemName: "power")
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 104, height: 104)
                                .background(
                                    Circle().fill(
                                        LinearGradient(colors: model.connected ?
                                            [.green, .mint] : [.blue, .cyan],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)))
                                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 4).padding(-9))
                                .padding(14)
                                .background(Circle().fill(.blue.opacity(0.09)))
                                .shadow(color: .blue.opacity(0.18), radius: 16, y: 7)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy || model.connecting ||
                                  (!model.connected && model.selected == nil))
                        .accessibilityLabel(model.connected ? "断开 VPN" : "连接 VPN")
                        Text(statusTitle)
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .foregroundStyle(model.connected ? .green : .primary)
                        Text(model.connectionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        if let active = model.activeProfile {
                            Label("当前连接：\(active.name)", systemImage: "checkmark.shield")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if model.connected && model.activeProfileID != model.selectedID,
                           model.selectedID != nil {
                            Button("切换至所选配置…") { confirmSwitch = true }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 38).padding(.horizontal, 20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 23))
                    .overlay(RoundedRectangle(cornerRadius: 23)
                        .strokeBorder(.primary.opacity(0.07)))

                    VStack(alignment: .leading, spacing: 16) {
                        VPNPanel("快速连接", symbol: "slider.horizontal.3") {
                            Picker("配置文件", selection: $model.selectedID) {
                                Text("请选择配置").tag(UUID?.none)
                                ForEach(model.profiles) { profile in
                                    Text(profile.name).tag(Optional(profile.id))
                                }
                            }
                            .disabled(model.profiles.isEmpty)
                            .pickerStyle(.menu)
                            if let profile = model.selected {
                                LabeledContent("路由模式", value: profile.mode.rawValue)
                                LabeledContent("配置文件", value: profile.sourceFilename)
                            } else {
                                Text("导入 .ovpn 配置后即可选择连接。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Divider()
                            Toggle("在 macOS 钥匙串中记住凭据",
                                   isOn: $model.rememberCredentials)
                            TextField("用户名（按需填写）", text: $model.username)
                                .textFieldStyle(.roundedBorder)
                            SecureField("密码（按需填写）", text: $model.password)
                                .textFieldStyle(.roundedBorder)
                            Text("凭据仅用于所选配置；密码在连接尝试后会从界面状态清除。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VPNPanel("连接保护", symbol: "shield.lefthalf.filled") {
                            Label("Managed VPN 遇到重连会安全断开",
                                  systemImage: "checkmark.shield")
                                .font(.callout)
                            Text("PF Kill Switch 尚未启用；此版本不承诺网络流量零泄漏。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 360)
                }
                HStack(spacing: 16) {
                    VPNPanel("累计接收", symbol: "arrow.down.circle") {
                        Text(trafficText)
                            .font(.system(size: 25, weight: .semibold, design: .rounded))
                    }
                    VPNPanel("累计发送", symbol: "arrow.up.circle") {
                        Text(model.traffic.map {
                            ByteCountFormatter.string(fromByteCount:
                                Int64(clamping: $0.sentBytes), countStyle: .file)
                        } ?? "—")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                    }
                    VPNPanel("中国 IPv4 规则", symbol: "list.bullet.rectangle") {
                        Text(model.rules.map { "\($0.routes.count) 条" } ?? "未下载")
                            .font(.system(size: 25, weight: .semibold, design: .rounded))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
        }
        .confirmationDialog("切换 VPN 配置？", isPresented: $confirmSwitch) {
            Button("断开当前连接并切换") { Task { await model.switchToSelected() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将先验证旧连接完全退出，再连接新配置；过程中网络可能短暂中断。")
        }
    }
}

private struct ProfileLibrary: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
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
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("配置文件").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("\(model.profiles.count) 份配置 · 安全存储于本机")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 19)
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索名称、分组、文件", text: $query)
                            .textFieldStyle(.plain)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(filtered) { profile in
                                Button { model.selectedID = profile.id } label: {
                                    HStack(spacing: 11) {
                                        Image(systemName: "network")
                                            .foregroundStyle(.blue)
                                            .frame(width: 35, height: 35)
                                            .background(.blue.opacity(0.09),
                                                        in: RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(profile.name).font(.callout.weight(.semibold))
                                                .lineLimit(1)
                                            Text(profile.group + " · " + profile.sourceFilename)
                                                .font(.caption2).foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        if profile.isFavorite {
                                            Image(systemName: "star.fill").foregroundStyle(.orange)
                                        }
                                    }
                                    .padding(9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selectedID == profile.id ?
                                        Color.accentColor.opacity(0.13) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(13)
                .frame(width: 260)
                .background(.thinMaterial)
                Divider().opacity(0.35)
                if let profile = model.selected {
                    ProfileDetail(profile: profile).id(profile.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up.slash")
                            .font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("尚未选择配置文件").font(.title3.weight(.semibold))
                        Text("点击窗口右上角「导入 .ovpn」开始。")
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

private struct RoutingWorkspace: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WorkspaceHeading(title: "路由与规则",
                    subtitle: "按配置管理策略，保留已经验证的网络规则版本",
                    symbol: "point.3.connected.trianglepath.dotted")
                VPNPanel("连接策略", symbol: "arrow.triangle.branch") {
                    if let profile = model.selected {
                        Text("当前编辑：\(profile.name)")
                            .font(.callout.weight(.medium))
                        Picker("路由模式", selection: Binding(
                            get: { profile.mode },
                            set: { newMode in Task { await model.setMode(newMode) } }
                        )) {
                            Text("原始配置").tag(RoutingMode.original)
                            Text("全局 VPN").tag(RoutingMode.fullVPN)
                            Text("中国 IPv4 直连").tag(RoutingMode.chinaDirect)
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.connected || model.connecting || model.busy)
                        Text("修改仅影响所选配置的下一次连接；不改变正在运行的隧道。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("请先导入并选择一个 VPN 配置。")
                            .foregroundStyle(.secondary)
                    }
                }
                VPNPanel("中国 IPv4 分流数据", symbol: "globe.asia.australia") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.rules.map { "\($0.routes.count) 个已校验的网段" } ?? "本机尚未缓存规则")
                                .font(.headline)
                            Text("按需更新；旧版规则在变更异常时保留。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("立即更新") { Task { await model.refreshRules() } }
                            .disabled(model.busy)
                    }
                    if !model.ruleSnapshots.isEmpty {
                        Divider()
                        Text("历史规则").font(.callout.weight(.semibold))
                        ForEach(model.ruleSnapshots.prefix(5)) { snapshot in
                            HStack {
                                Text(snapshot.savedAt, format: .dateTime.year().month().day())
                                Text("\(snapshot.routeCount) 个网段")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("恢复此版本") {
                                    Task { await model.restoreRuleSnapshot(snapshot.id) }
                                }.disabled(model.busy)
                            }
                        }
                    }
                }
                VPNPanel("IPv6 注册数据预览", symbol: "globe") {
                    HStack {
                        Text(model.ipv6Preview.map {
                            "\($0.routes.count) 个 APNIC 中国注册前缀"
                        } ?? "未下载预览")
                        Spacer()
                        Button("刷新预览") { Task { await model.updateIPv6Preview() } }
                            .disabled(model.busy)
                    }
                    Text("仅展示资源注册地，并非实际 IP 地理位置；尚未应用于系统路由，不代表 IPv6 分流或 Kill Switch 已实现。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28).frame(maxWidth: 1050, alignment: .leading)
        }
    }
}

struct SystemSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WorkspaceHeading(title: "设置与维护",
                    subtitle: "管理签名辅助服务、网络恢复与软件更新",
                    symbol: "gearshape")
                VPNPanel("系统服务", symbol: "lock.shield") {
                    LabeledContent("特权 Helper", value: model.helperStatus)
                    Text("启动真实 VPN 需要已审计的 OpenVPN 引擎、Developer ID 签名和用户授权。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("启用 Helper…") { model.requestHelper() }
                        Button("停用后台服务…") { Task { await model.disableServices() } }
                    }
                }
                VPNPanel("异常网络恢复", symbol: "cross.case") {
                    Text("仅在异常会话已被证明退出、路由变更可以安全恢复时清理遗留状态。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("尝试安全恢复…") { Task { await model.retryNetworkRecovery() } }
                        .disabled(model.connected || model.connecting)
                }
                VPNPanel("应用更新", symbol: "arrow.down.app") {
                    HStack {
                        Button("检查更新") { Task { await model.checkForUpdates() } }
                        Button("下载已验证的安装包…") {
                            Task { await model.downloadVerifiedUpdate() }
                        }
                        .disabled(model.availableInstaller == nil || model.busy)
                        Button("查看发布说明…") { model.viewReleasePage() }
                            .disabled(model.availableReleasePage == nil)
                    }
                    Text("安装由 macOS Installer 完成，应用不会静默执行特权安装。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VPNPanel("版本说明", symbol: "info.circle") {
                    LabeledContent("开发阶段", value: "Alpha")
                    LabeledContent("最低系统版本", value: "macOS 13")
                    Text("正式 PF Kill Switch、IPv6 分流和防泄漏认证尚未完成。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28).frame(maxWidth: 900, alignment: .leading)
        }
    }
}

struct ProfileDetail: View {
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
                VPNPanel("基本信息", symbol: "person.crop.rectangle") {
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
                VPNPanel("配置编辑与历史版本", symbol: "doc.text") {
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




                HStack {
                    Button("Export configuration preview…") { Task { await model.exportPreview() } }
                        .disabled(profile.mode == .chinaDirect && model.rules == nil)
                    Spacer()
                    Button("Remove Profile", role: .destructive) { Task { await model.deleteSelected() } }
                }
                Text("The privileged helper requires a signed app bundle and installed OpenVPN CLI. Native route and DNS operations must be validated on your Mac before relying on this as a production VPN.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(26).frame(maxWidth: 820, alignment: .leading)
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
