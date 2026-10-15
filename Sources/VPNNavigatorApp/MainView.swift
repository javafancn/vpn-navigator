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
    @State private var tab: WorkspaceTab = .overview
    @State private var importing = false

    var body: some View {
        ZStack {
            GlassAtmosphere()
            HStack(spacing: 0) {
                sidebar.frame(width: 180)
                Rectangle().fill(Color.white.opacity(0.26)).frame(width: 1)
                VStack(spacing: 0) {
                    topBar
                    Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1)
                    Group {
                        switch tab {
                        case .overview: ConnectionOverview()
                        case .profiles: ProfileLibrary()
                        case .routing: RoutingWorkspace()
                        case .diagnostics: NetworkDiagnosticsView()
                        case .settings: SystemSettingsPane()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 990, minHeight: 635)
        .preferredColorScheme(nil)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.init(filenameExtension: "ovpn")!],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task {
                    for url in urls { await model.importFile(url) }
                    tab = .profiles
                }
            case .failure(let error):
                model.message = error.localizedDescription
            }
        }
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
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 37, height: 37)
                    .background(.white.opacity(0.48),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.45)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN Navigator").font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    Text("网络连接控制台").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 42)
            .padding(.bottom, 21)

            ForEach(WorkspaceTab.allCases) { item in
                Button { withAnimation(.easeInOut(duration: 0.16)) { tab = item } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 22)
                        Text(item.title).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tab == item ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background {
                        if tab == item {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(LinearGradient(colors: [
                                    Color(red: 0.12, green: 0.53, blue: 1),
                                    Color(red: 0.03, green: 0.39, blue: 0.91)
                                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .shadow(color: .blue.opacity(0.28), radius: 9, y: 3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.connected ? Color.green : Color.secondary.opacity(0.7))
                        .frame(width: 7, height: 7)
                    Text(model.connected ? "已连接" : model.connecting ? "连接中" : "未连接")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(model.activeProfile?.name ?? "选择配置后开始")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("macOS 13+ · Alpha")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .background(Color.white.opacity(0.39))
        .background(.ultraThinMaterial)
    }

    private var topBar: some View {
        HStack {
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.83))
            Spacer()
            Text("安全 · 高效 · 专业")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.trailing, 10)
            Button { importing = true } label: {
                Label("导入配置", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.regular)
        }
        .padding(.leading, 24).padding(.trailing, 20)
        .frame(height: 45)
        .background(Color.white.opacity(0.42))
        .background(.ultraThinMaterial)
    }
}

struct WorkspaceHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 40, height: 40)
                .background(Color.blue.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Color.white.opacity(0.45)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 21, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct VPNPanel<Content: View>: View {
    @Environment(\.colorScheme) private var appearance
    let title: String
    let symbol: String
    private let content: Content
    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appearance == .dark ? Color.white.opacity(0.91) : GlassPalette.ink.opacity(0.85))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 14)
    }
}

private struct ConnectionOverview: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmSwitch = false
    private var error: Bool { model.connectionStatus.hasPrefix("failed:") }
    private var statusTitle: String {
        if model.connected { return "已连接" }
        if model.connecting { return "正在连接" }
        if error { return "连接需要检查" }
        return "准备连接"
    }
    private var description: String {
        if !model.connected && !model.connecting { return "点击电源按钮开始建立连接" }
        return model.connectionStatus
    }
    private func formattedBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes),
                                         countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                WorkspaceHeading(title: "连接总览",
                    subtitle: "当前 VPN 连接状态与网络策略",
                    symbol: "globe.americas.fill")
                HStack(alignment: .top, spacing: 13) {
                    VStack(spacing: 9) {
                        Spacer(minLength: 0)
                        Button {
                            if !model.connected && model.selected == nil {
                                model.message = "请先点击右上角的导入配置，选择一个 .ovpn 文件。"
                            } else {
                                Task {
                                    if model.connected { await model.disconnect() }
                                    else { await model.connectSelected() }
                                }
                            }
                        } label: {
                            ZStack {
                                Circle().stroke(Color.blue.opacity(0.08), lineWidth: 16)
                                    .frame(width: 135, height: 135)
                                Circle().stroke(.white.opacity(0.9), lineWidth: 5)
                                    .frame(width: 130, height: 130)
                                Circle().stroke(Color.cyan.opacity(0.63), lineWidth: 2)
                                    .blur(radius: 5).frame(width: 141, height: 141)
                                Circle()
                                    .fill(LinearGradient(colors: model.connected ?
                                          [Color.green, Color.mint] :
                                          [Color(red: 0.0, green: 0.49, blue: 1),
                                           Color(red: 0.09, green: 0.76, blue: 0.98)],
                                          startPoint: .topLeading,
                                          endPoint: .bottomTrailing))
                                    .frame(width: 112, height: 112)
                                    .shadow(color: .blue.opacity(0.48), radius: 20, y: 5)
                                Image(systemName: "power")
                                    .font(.system(size: 39, weight: .light))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 155, height: 155)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy || model.connecting)
                        .accessibilityLabel(model.connected ? "断开 VPN" : "连接 VPN")
                        .help(model.connected ? "断开当前 VPN" : "连接所选 VPN")
                        Text(statusTitle)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(model.connected ? Color.green :
                                             error ? Color.orange : Color.primary)
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        if let active = model.activeProfile {
                            Label(active.name, systemImage: "checkmark.shield")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if model.connected && model.activeProfileID != model.selectedID &&
                           model.selectedID != nil {
                            Button("切换到所选配置") { confirmSwitch = true }
                                .controlSize(.small)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 275)
                    .padding(.horizontal, 15)
                    .glassCard(cornerRadius: 18)

                    VStack(spacing: 12) {
                        VPNPanel("快速连接", symbol: "slider.horizontal.3") {
                            Picker("配置文件", selection: $model.selectedID) {
                                Text("请选择配置").tag(UUID?.none)
                                ForEach(model.profiles) { profile in
                                    Text(profile.name).tag(Optional(profile.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(model.profiles.isEmpty)
                            .controlSize(.small)
                            if let profile = model.selected {
                                LabeledContent("路由模式", value: profile.mode.rawValue)
                                LabeledContent("配置文件", value: profile.sourceFilename)
                            }
                            DisclosureGroup("身份验证（按需）") {
                                Toggle("保存在钥匙串", isOn: $model.rememberCredentials)
                                TextField("用户名", text: $model.username)
                                SecureField("密码", text: $model.password)
                            }
                            .font(.system(size: 11))
                        }
                        VPNPanel("连接保护", symbol: "checkmark.shield") {
                            Label("受管连接异常时安全断开", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 11))
                            Text("PF Kill Switch 尚未启用，不能保证零泄漏。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 288)
                }
                HStack(spacing: 12) {
                    miniStatistic("累计接收", symbol: "arrow.down.circle.fill",
                                  value: formattedBytes(model.traffic?.receivedBytes),
                                  samples: model.receiveTrend.samples)
                    miniStatistic("累计发送", symbol: "arrow.up.circle.fill",
                                  value: formattedBytes(model.traffic?.sentBytes),
                                  samples: model.sendTrend.samples)
                    miniStatistic("中国 IPv4 规则", symbol: "globe.asia.australia.fill",
                                  value: model.rules.map { "\($0.routes.count) 条" } ?? "未下载")
                }
            }
            .padding(19)
            .frame(maxWidth: 1060, alignment: .leading)
        }
        .confirmationDialog("切换 VPN 配置？", isPresented: $confirmSwitch) {
            Button("断开当前连接并切换") { Task { await model.switchToSelected() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("应用将验证旧会话退出，然后连接新配置。")
        }
    }

    private func miniStatistic(_ title: String, symbol: String,
                               value: String, samples: [Double] = []) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if title != "中国 IPv4 规则" {
                TrafficSparkline(samples: samples)
                    .frame(height: 23)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(15)
        .glassCard(cornerRadius: 15)
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
                    Text("\(model.profiles.count) 份配置 · OpenVPN 配置库")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 14)
            HStack(spacing: 12) {
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
                                            .foregroundStyle(GlassPalette.blue)
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
                                        GlassPalette.blue.opacity(0.17) : Color.white.opacity(0.17),
                                        in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(width: 225)
                .glassCard(cornerRadius: 17)
                if let profile = model.selected {
                    ProfileDetail(profile: profile).id(profile.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .glassCard(cornerRadius: 18)
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
            .padding(.horizontal, 20)
            .padding(.bottom, 19)
        }
    }
}

private struct RoutingWorkspace: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                WorkspaceHeading(title: "路由与规则",
                    subtitle: "选择网络策略，管理已验证的中国 IPv4 规则",
                    symbol: "point.3.connected.trianglepath.dotted")
                HStack(alignment: .top, spacing: 13) {
                    VPNPanel("路由模式", symbol: "arrow.triangle.branch") {
                        if let profile = model.selected {
                            Text("所选配置 · \(profile.name)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Picker("连接模式", selection: Binding(
                                get: { profile.mode },
                                set: { newMode in Task { await model.setMode(newMode) } }
                            )) {
                                Text("Original · 遵循配置文件").tag(RoutingMode.original)
                                Text("Full VPN · 全局 IPv4").tag(RoutingMode.fullVPN)
                                Text("中国 IPv4 直连").tag(RoutingMode.chinaDirect)
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                            .disabled(model.connected || model.connecting || model.busy)
                            Divider()
                            Text("原始模式遵循 .ovpn；全局模式将 IPv4 默认路由指向 VPN；中国直连模式对已识别中国 IPv4 网段使用物理网络。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("连接时不可改动路由模式。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            Label("请先导入并选择配置文件", systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 13) {
                        VPNPanel("中国 IPv4 规则", symbol: "globe.asia.australia") {
                            HStack(spacing: 12) {
                                Image(systemName: "globe.asia.australia.fill")
                                    .font(.system(size: 26)).foregroundStyle(.blue)
                                    .frame(width: 44, height: 44)
                                    .background(Color.blue.opacity(0.09),
                                                in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.rules.map { "\($0.routes.count) 个网段" } ?? "尚未下载")
                                        .font(.headline)
                                    Text("本机经验证的 IPv4 分流数据")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            HStack {
                                Button("更新规则") { Task { await model.refreshRules() } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.busy)
                                Spacer()
                                Text("异常更新将保留旧版")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if !model.ruleSnapshots.isEmpty {
                                Divider()
                                Text("历史快照").font(.system(size: 11, weight: .semibold))
                                ForEach(model.ruleSnapshots.prefix(4)) { snapshot in
                                    HStack {
                                        Text(snapshot.savedAt, style: .date)
                                        Text("\(snapshot.routeCount) 个网段")
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button("恢复") {
                                            Task { await model.restoreRuleSnapshot(snapshot.id) }
                                        }.disabled(model.busy)
                                    }.font(.system(size: 11))
                                }
                            }
                        }
                        VPNPanel("IPv6 数据预览 · 未启用", symbol: "shield.lefthalf.filled") {
                            HStack(spacing: 9) {
                                Text(model.ipv6Preview.map {
                                    "\($0.routes.count) 个 APNIC 注册前缀"
                                } ?? "尚未下载预览")
                                    .font(.system(size: 11))
                                Spacer()
                                Button("刷新") { Task { await model.updateIPv6Preview() } }
                                    .disabled(model.busy)
                            }
                            Text("仅显示注册数据，不安装 IPv6 路由或防火墙。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(22)
            .frame(maxWidth: 1050, alignment: .leading)
        }
    }
}

struct SystemSettingsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                WorkspaceHeading(title: "设置与维护",
                    subtitle: "安全地管理后台服务、应用版本与网络恢复",
                    symbol: "gearshape.fill")

                settingRow("特权辅助服务",
                           subtitle: "管理允许 OpenVPN 运行的签名辅助服务",
                           symbol: "lock.shield.fill",
                           status: model.helperStatus,
                           statusColor: GlassPalette.blue) {
                    Button("启用服务…") { model.requestHelper() }
                        .buttonStyle(.borderedProminent)
                    Button("停用…") { Task { await model.disableServices() } }
                }
                settingRow("应用更新",
                           subtitle: "通过已验证的安装程序进行版本更新",
                           symbol: "arrow.triangle.2.circlepath",
                           status: "手动检查",
                           statusColor: .secondary) {
                    Button("检查更新") { Task { await model.checkForUpdates() } }
                        .buttonStyle(.borderedProminent)
                    Button("下载安装包…") {
                        Task { await model.downloadVerifiedUpdate() }
                    }
                    .disabled(model.availableInstaller == nil || model.busy)
                    Button("发布说明…") { model.viewReleasePage() }
                        .disabled(model.availableReleasePage == nil)
                }
                settingRow("安全网络恢复",
                           subtitle: "仅在确认旧 OpenVPN 进程退出后恢复残留路由",
                           symbol: "cross.case.fill",
                           status: "人工确认",
                           statusColor: .orange) {
                    Button("尝试安全恢复…") { Task { await model.retryNetworkRecovery() } }
                        .disabled(model.connected || model.connecting)
                }
                settingRow("关于 VPN Navigator",
                           subtitle: "原生 macOS 网络配置与诊断客户端",
                           symbol: "info.circle.fill",
                           status: "Alpha · macOS 13+",
                           statusColor: GlassPalette.blue) {
                    Label("PF Kill Switch 与 IPv6 分流尚未实现",
                          systemImage: "exclamationmark.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 1050, alignment: .leading)
        }
    }

    private func settingRow<Actions: View>(
        _ title: String, subtitle: String, symbol: String,
        status: String, statusColor: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                GlassIcon(symbol: symbol, size: 41)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                actions()
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(15)
        .glassCard(cornerRadius: 15)
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
    @State private var tab: ProfileInspectorTab = .details
    @State private var draftName = ""
    @State private var draftGroup = ""
    @State private var draftNotes = ""
    @State private var draftFavorite = false
    @State private var editorText = ""
    @State private var showingEditor = false
    @State private var confirmDelete = false
    @State private var history: [ProfileRevision] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 13) {
                    GlassIcon(symbol: "network.badge.shield.half.filled", size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                        Text(profile.sourceFilename)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
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
                    .buttonStyle(.bordered)
                    .help("收藏此配置")
                }
                Picker("配置页面", selection: $tab) {
                    ForEach(ProfileInspectorTab.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)

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
                    Text("导入：")
                        .foregroundStyle(.secondary)
                    Text(profile.importedAt, format: .dateTime.year().month().day())
                    Spacer()
                    Button("导出预览…") { Task { await model.exportPreview() } }
                        .disabled(profile.mode == .chinaDirect && model.rules == nil)
                    Button("删除配置…", role: .destructive) { confirmDelete = true }
                }
                .font(.system(size: 11))
                .padding(.top, 6)
            }
            .padding(19)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .buttonStyle(.borderedProminent)
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

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 13) {
            editorRow("名称") {
                TextField("配置名称", text: $draftName)
                    .textFieldStyle(.roundedBorder)
            }
            editorRow("分组") {
                TextField("分组名称", text: $draftGroup)
                    .textFieldStyle(.roundedBorder)
            }
            editorRow("配置文件") {
                Label(profile.sourceFilename, systemImage: "doc.text")
                    .font(.system(size: 12)).lineLimit(1)
                Spacer()
            }
            editorRow("备注") {
                TextField("添加备注信息", text: $draftNotes)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("OpenVPN · 本地配置")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("保存更改") {
                    Task {
                        await model.updateMetadata(name: draftName,
                            group: draftGroup, notes: draftNotes, favorite: draftFavorite)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 14)
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("安全编辑", systemImage: "curlybraces")
                .font(.system(size: 14, weight: .semibold))
            Text("保留原始 .ovpn 文件及版本快照，不会执行导入文件中的脚本。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("编辑 .ovpn 文件…") {
                Task {
                    if let text = await model.editSource(for: profile) {
                        editorText = text
                        showingEditor = true
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            LabeledContent("源文件", value: profile.sourceFilename)
            LabeledContent("保存位置", value: "本机私有配置仓库")
            Text("只有断开连接后才能更改或恢复配置。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(17)
        .glassCard(cornerRadius: 14)
    }

    private var routeMode: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("所选配置的默认路由策略")
                .font(.system(size: 12, weight: .medium))
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
            Text("中国 IPv4 直连需要已经下载的网段规则；IPv6 分流与 Kill Switch 尚未实现。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(17)
        .glassCard(cornerRadius: 14)
    }

    private var revisions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已保存的配置版本")
                    .font(.system(size: 13, weight: .semibold))
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
                    .font(.system(size: 11))
                    Divider().opacity(0.3)
                }
            }
            Text("版本保存在本机，不会上传至云端。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard(cornerRadius: 14)
    }

    private func editorRow<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
        }
    }
}
