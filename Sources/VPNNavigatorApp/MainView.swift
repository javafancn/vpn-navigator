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
                sidebar.frame(width: 184)
                Rectangle().fill(Color.white.opacity(0.24)).frame(width: 1)
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
        .frame(minWidth: 1015, minHeight: 620)
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
                BrandMark(size: 37)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN Navigator").font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    Text("网络连接控制台").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 42)
            .padding(.bottom, 24)

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
                    .frame(height: 36)
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
                .padding(.bottom, 5)
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
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial).opacity(0.35)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .background {
            Rectangle().fill(.regularMaterial).opacity(0.53)
        }
        .background(Color.white.opacity(0.09))
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
        .background {
            Rectangle().fill(.regularMaterial).opacity(0.46)
        }
        .background(Color.white.opacity(0.12))
    }
}

struct WorkspaceHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 11) {
            if symbol == "globe.americas.fill" {
                BrandMark(size: 40)
            } else {
                GlassIcon(symbol: symbol, size: 40)
            }
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
        .padding(15)
        .glassCard(cornerRadius: 15)
    }
}

private struct ConnectionOverview: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmSwitch = false

    private var hasError: Bool { model.connectionStatus.hasPrefix("failed:") }
    private var statusTitle: String {
        if model.connected { return "已连接" }
        if model.connecting { return "正在连接" }
        if hasError { return "连接需要检查" }
        return "准备连接"
    }
    private var statusDescription: String {
        if model.connected { return "VPN 已建立连接，流量统计来自真实会话" }
        if model.connecting { return "正在与 VPN 服务建立连接…" }
        if hasError { return "无法建立连接，请检查辅助服务和配置" }
        return "点击电源按钮开始建立连接"
    }
    private func formattedBytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                WorkspaceHeading(title: "连接总览",
                    subtitle: "清晰掌控当前 VPN 状态与网络策略",
                    symbol: "globe.americas.fill")

                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 7) {
                        Spacer(minLength: 9)
                        Button {
                            guard model.selected != nil || model.connected else {
                                model.message = "请先导入并选择一个 .ovpn 配置文件。"
                                return
                            }
                            Task {
                                if model.connected { await model.disconnect() }
                                else { await model.connectSelected() }
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(GlassPalette.cyan.opacity(0.10))
                                    .frame(width: 168, height: 168)
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.48), lineWidth: 2)
                                    .frame(width: 162, height: 162)
                                Circle()
                                    .strokeBorder(GlassPalette.cyan.opacity(0.60), lineWidth: 6)
                                    .blur(radius: 7)
                                    .frame(width: 152, height: 152)
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.95), lineWidth: 4)
                                    .frame(width: 143, height: 143)
                                Circle()
                                    .fill(
                                        LinearGradient(colors: model.connected ?
                                            [Color(red: 0.19, green: 0.76, blue: 0.57),
                                             Color(red: 0.04, green: 0.64, blue: 0.47)] :
                                            [Color(red: 0.11, green: 0.64, blue: 1),
                                             Color(red: 0.02, green: 0.41, blue: 0.98)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 126, height: 126)
                                    .shadow(color: GlassPalette.blue.opacity(0.42),
                                            radius: 15, y: 5)
                                Image(systemName: "power")
                                    .font(.system(size: 42, weight: .ultraLight))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 173, height: 173)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy || model.connecting)
                        .help(model.connected ? "断开 VPN 连接" : "连接当前配置")
                        .accessibilityLabel(model.connected ? "断开 VPN" : "连接 VPN")

                        Text(statusTitle)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(model.connected ? Color.green :
                                             hasError ? Color.orange : Color.primary)
                        if model.connected {
                            Label("安全连接已建立", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                        } else {
                            Text(statusDescription)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        if model.connected && model.activeProfileID != model.selectedID &&
                           model.selectedID != nil {
                            Button("切换到所选配置") { confirmSwitch = true }
                                .controlSize(.small)
                        }
                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 304)
                    .glassCard(cornerRadius: 17, active: true)

                    VStack(spacing: 12) {
                        VPNPanel("快速连接", symbol: "slider.horizontal.3") {
                            Picker("配置文件", selection: $model.selectedID) {
                                Text("请选择配置").tag(UUID?.none)
                                ForEach(model.profiles) { profile in
                                    Text(profile.name).tag(Optional(profile.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .disabled(model.profiles.isEmpty)
                            .font(.system(size: 11))

                            HStack(spacing: 8) {
                                Text("路由模式").foregroundStyle(.secondary)
                                Spacer(minLength: 2)
                                Text(model.selected?.mode.rawValue ?? "—")
                                    .lineLimit(1)
                            }
                            HStack(spacing: 8) {
                                Text("配置文件").foregroundStyle(.secondary)
                                Spacer(minLength: 2)
                                Text(model.selected?.sourceFilename ?? "未选择")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.system(size: 11))

                            DisclosureGroup("身份验证（按需）") {
                                VStack(spacing: 6) {
                                    Toggle("保存在钥匙串", isOn: $model.rememberCredentials)
                                    TextField("用户名", text: $model.username)
                                    SecureField("密码", text: $model.password)
                                }
                                .textFieldStyle(.roundedBorder)
                            }
                            .font(.system(size: 11))
                        }
                        VPNPanel("连接保护", symbol: "checkmark.shield") {
                            Label("受管连接异常时安全断开",
                                  systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                            Text("PF Kill Switch 尚未启用，不能保证零泄漏。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 304, alignment: .top)
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
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if title != "中国 IPv4 规则" {
                TrafficSparkline(samples: samples)
                    .frame(height: 27)
            } else {
                Spacer(minLength: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 89)
        .padding(13)
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
        VStack(alignment: .leading, spacing: 13) {
            WorkspaceHeading(title: "配置文件",
                subtitle: "管理和编辑 VPN 配置文件",
                symbol: "square.stack.3d.up.fill")

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("搜索配置文件…", text: $query)
                    .font(.system(size: 12))
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
            .padding(.horizontal, 12)
            .frame(height: 35)
            .glassCard(cornerRadius: 10)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("全部配置 (\(filtered.count))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 3)

                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(filtered) { profile in
                                Button { model.selectedID = profile.id } label: {
                                    HStack(spacing: 9) {
                                        GlassIcon(symbol: "globe.americas.fill",
                                                  color: profile.isFavorite ?
                                                    GlassPalette.blue : GlassPalette.cyan,
                                                  size: 34)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(profile.name)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(profile.sourceFilename)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer(minLength: 3)
                                        if profile.isFavorite {
                                            Image(systemName: "star.fill")
                                                .foregroundStyle(.orange)
                                                .font(.system(size: 11))
                                        }
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        model.selectedID == profile.id ?
                                          GlassPalette.blue.opacity(0.17) :
                                          Color.clear,
                                        in: RoundedRectangle(cornerRadius: 11))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(
                                    model.selectedID == profile.id ? .isSelected : [])
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Label("没有匹配的配置", systemImage: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(11)
                .frame(width: 245)
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
                                .font(.system(size: 11))
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
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }
}

private struct RoutingWorkspace: View {
    @EnvironmentObject private var model: AppModel

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
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                WorkspaceHeading(title: "路由与规则",
                    subtitle: "管理 VPN 路由模式与中国 IPv4 规则",
                    symbol: "point.3.connected.trianglepath.dotted")

                HStack(alignment: .top, spacing: 13) {
                    VPNPanel("路由模式", symbol: "arrow.triangle.branch") {
                        if let profile = model.selected {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(RoutingMode.allCases) { mode in
                                    Button {
                                        Task { await model.setMode(mode) }
                                    } label: {
                                        HStack(alignment: .center, spacing: 11) {
                                            Image(systemName: profile.mode == mode ?
                                                  "largecircle.fill.circle" : "circle")
                                                .font(.system(size: 17))
                                                .foregroundStyle(profile.mode == mode ?
                                                                 GlassPalette.blue : Color.secondary)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(title(for: mode))
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(.primary)
                                                Text(subtitle(for: mode))
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .padding(11)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            profile.mode == mode ?
                                                GlassPalette.blue.opacity(0.13) :
                                                Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 12))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(model.connected || model.connecting || model.busy)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            Text("所选配置：\(profile.name) · 连接期间不可改动路由模式")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Label("请先导入并选择配置文件", systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 12) {
                        VPNPanel("中国 IPv4 规则", symbol: "globe.asia.australia.fill") {
                            HStack(spacing: 11) {
                                GlassIcon(symbol: "globe.asia.australia.fill", size: 46)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.rules.map { "\($0.routes.count) 条规则" } ?? "未下载")
                                        .font(.system(size: 19, weight: .bold, design: .rounded))
                                    Text("已验证的中国 IPv4 网段")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            Divider().opacity(0.3)
                            HStack {
                                Text("规则来源")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("chnroutes2").lineLimit(1)
                            }
                            HStack {
                                Text("规则版本")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let saved = model.ruleSnapshots.first?.savedAt {
                                    Text(saved, format: .dateTime.year().month().day())
                                } else {
                                    Text("尚无快照")
                                }
                            }
                            HStack {
                                Text("状态")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(model.rules == nil ? "未下载" : "已缓存 · 已验证")
                                    .foregroundStyle(model.rules == nil ?
                                                     Color.secondary : Color.green)
                            }
                            .font(.system(size: 11))

                            HStack(spacing: 8) {
                                Button("更新规则") {
                                    Task { await model.refreshRules() }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.busy)
                                if let saved = model.ruleSnapshots.dropFirst().first {
                                    Button("恢复旧版") {
                                        Task { await model.restoreRuleSnapshot(saved.id) }
                                    }
                                    .disabled(model.busy)
                                }
                                Spacer(minLength: 0)
                            }
                            .controlSize(.small)
                        }

                        VPNPanel("IPv6 规则（预览）", symbol: "shield.lefthalf.filled") {
                            HStack(spacing: 6) {
                                Text(model.ipv6Preview.map {
                                    "\($0.routes.count) 个 APNIC 注册前缀"
                                } ?? "未下载")
                                    .font(.system(size: 11))
                                Spacer(minLength: 0)
                                Button("刷新") {
                                    Task { await model.updateIPv6Preview() }
                                }
                                .controlSize(.small)
                                .disabled(model.busy)
                            }
                            Text("仅供查看，不修改系统 IPv6 路由")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
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
