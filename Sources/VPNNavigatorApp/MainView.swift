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
                sidebar.frame(width: 254)
                Rectangle().fill(Color.white.opacity(0.24)).frame(width: 1)
                VStack(spacing: 0) {
                    Group {
                        switch tab {
                        case .overview: ConnectionOverview()
                        case .profiles: ProfileLibrary(onImport: { importing = true })
                        case .routing: RoutingWorkspace()
                        case .diagnostics: NetworkDiagnosticsView()
                        case .settings: SystemSettingsPane()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        Button { importing = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(GlassPalette.ink)
                                .frame(width: 34, height: 34)
                                .glassCard(cornerRadius: 10)
                        }
                        .buttonStyle(.plain)
                        .help("导入 VPN 配置")
                        .padding(.top, 16)
                        .padding(.trailing, 18)
                    }
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
                BrandMark(size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN Navigator").font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    Text("网络连接控制台").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 19)
            .padding(.trailing, 8)
            .padding(.top, 53)
            .padding(.bottom, 30)

            ForEach(WorkspaceTab.allCases) { item in
                Button { withAnimation(.easeInOut(duration: 0.16)) { tab = item } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(tab == item ? Color.white : GlassPalette.blue)
                            .frame(width: 24)
                        Text(item.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tab == item ? Color.white : Color.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 43)
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
                .padding(.horizontal, 15)
                .padding(.bottom, 9)
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
        .background(Color(red: 0.85, green: 0.90, blue: 1.0).opacity(0.20))
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
            if symbol == "globe.americas.fill" {
                BrandMark(size: 56)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
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
    init(_ title: String, symbol: String, minContentHeight: CGFloat = 0,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.minContentHeight = minContentHeight
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
        .frame(minHeight: minContentHeight, alignment: .topLeading)
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
                    .padding(.bottom, 33)

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
                                    .stroke(GlassPalette.cyan.opacity(0.68), lineWidth: 17)
                                    .frame(width: 183, height: 183)
                                    .blur(radius: 17)
                                Circle()
                                    .fill(GlassPalette.cyan.opacity(0.14))
                                    .frame(width: 195, height: 195)
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.40), lineWidth: 2)
                                    .frame(width: 189, height: 189)
                                Circle()
                                    .strokeBorder(GlassPalette.cyan.opacity(0.85), lineWidth: 5)
                                    .frame(width: 179, height: 179)
                                    .shadow(color: GlassPalette.cyan.opacity(0.7), radius: 11)
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.96), lineWidth: 5)
                                    .frame(width: 170, height: 170)
                                Circle()
                                    .fill(RadialGradient(
                                        colors: model.connected ?
                                            [Color(red: 0.03, green: 0.61, blue: 0.40),
                                             Color(red: 0.20, green: 0.83, blue: 0.65)] :
                                            [Color(red: 0.00, green: 0.40, blue: 0.98),
                                             Color(red: 0.02, green: 0.59, blue: 1.00),
                                             Color(red: 0.11, green: 0.77, blue: 1.00)],
                                        center: .center, startRadius: 0, endRadius: 83))
                                    .frame(width: 156, height: 156)
                                    .shadow(color: GlassPalette.blue.opacity(0.37),
                                            radius: 15, y: 5)
                                Image(systemName: "power")
                                    .font(.system(size: 49, weight: .regular))
                                    .foregroundStyle(.white)
                                    .shadow(color: .white.opacity(0.65), radius: 4)
                            }
                            .frame(width: 205, height: 205)
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
                     .frame(height: 316)
                    .glassCard(cornerRadius: 17, active: true)

                    VStack(spacing: 12) {
                        VPNPanel("快速连接", symbol: "slider.horizontal.3", minContentHeight: 185) {
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

                            Picker("路由模式", selection: Binding(
                                get: { model.selected?.mode ?? .original },
                                set: { value in Task { await model.setMode(value) } }
                            )) {
                                Text("Original").tag(RoutingMode.original)
                                Text("Full VPN").tag(RoutingMode.fullVPN)
                                Text("中国 IPv4 直连").tag(RoutingMode.chinaDirect)
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .disabled(model.selected == nil ||
                                      model.busy || model.connected || model.connecting)
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
                        VPNPanel("当前连接", symbol: "globe.americas.fill") {
                            HStack(spacing: 8) {
                                BrandMark(size: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.activeProfile?.name ??
                                         model.selected?.name ?? "尚未选择配置")
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                    Text(model.connected ? "VPN 会话运行中" : "等待连接")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
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
                        .frame(width: 202)
                    miniStatistic("累计发送", symbol: "arrow.up.circle.fill",
                        value: formattedBytes(model.traffic?.sentBytes),
                        samples: model.sendTrend.samples)
                        .frame(width: 202)
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.green)
                            .frame(width: 39, height: 39)
                            .background(Color.green.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("连接保护")
                                .font(.system(size: 12, weight: .semibold))
                            Label("受管连接异常时安全断开",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 10))
                            Text("PF Kill Switch 尚未启用，不能保证零泄漏。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 112, alignment: .top)
                    .glassCard(cornerRadius: 15)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 29)
            .padding(.bottom, 16)
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
            TrafficSparkline(samples: samples)
                .frame(height: 27)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 130)
        .padding(13)
        .glassCard(cornerRadius: 15)
    }
}

private struct ProfileLibrary: View {
    @EnvironmentObject private var model: AppModel
    let onImport: () -> Void
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

            HStack(spacing: 10) {
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
                .frame(height: 36)
                .glassCard(cornerRadius: 10)
                Button(action: onImport) {
                    Label("导入配置", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(height: 24)
                }
                .buttonStyle(.borderedProminent)
                .tint(GlassPalette.blue)
            }

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
        .padding(.top, 31)
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
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(RoutingMode.allCases) { mode in
                                let current = model.selected?.mode ?? .original
                                Button {
                                    Task { await model.setMode(mode) }
                                } label: {
                                    HStack(alignment: .center, spacing: 12) {
                                        Image(systemName: current == mode ?
                                              "largecircle.fill.circle" : "circle")
                                            .font(.system(size: 19))
                                            .foregroundStyle(current == mode ?
                                                GlassPalette.blue : Color.gray)
                                        VStack(alignment: .leading, spacing: 4) {
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
                                    .padding(.horizontal, 11)
                                    .frame(maxWidth: .infinity, minHeight: 64,
                                           alignment: .leading)
                                    .background(
                                        current == mode ?
                                            GlassPalette.blue.opacity(0.13) :
                                            Color.white.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(model.selected == nil ||
                                          model.connected || model.connecting || model.busy)
                            }
                        }
                        Text(model.selected.map {
                            "所选配置：\($0.name)"
                        } ?? "导入配置后即可切换路由模式")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
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
            .padding(.horizontal, 20)
            .padding(.top, 31)
            .padding(.bottom, 20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
    }
}

struct SystemSettingsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WorkspaceHeading(title: "设置与维护",
                    subtitle: "", symbol: "gearshape")

                settingsRow("特权助手",
                    subtitle: "管理系统使用此配置所需的特权助手",
                    symbol: "shield.lefthalf.filled") {
                    Menu {
                        Button("启用服务…") { model.requestHelper() }
                        Button("停用服务…") {
                            Task { await model.disableServices() }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: model.helperStatus == "已启用" ?
                                  "checkmark.circle.fill" : "shield")
                            Text(model.helperStatus)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(model.helperStatus == "已启用" ?
                                         Color.green : Color.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                settingsRow("应用更新",
                    subtitle: "当前版本：1.0.0 (Build 100) · 检查经过验证的更新",
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
                        HStack(spacing: 7) {
                            Text("检查更新")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                settingsRow("安全恢复",
                    subtitle: "遇到网络问题时，可尝试恢复残留的网络设置",
                    symbol: "cross.case.fill") {
                    Button("开始恢复") {
                        Task { await model.retryNetworkRecovery() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(model.connected || model.connecting)
                }
                settingsRow("关于",
                    subtitle: "VPN Navigator · 原生 macOS 网络配置工具",
                    symbol: "info.circle.fill") {
                    Menu {
                        Text("Alpha · macOS 13+")
                        Text("PF Kill Switch 与 IPv6 分流尚未实现")
                    } label: {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 20)
            .frame(maxWidth: 1060, alignment: .leading)
        }
    }

    private func settingsRow<Actions: View>(
        _ title: String, subtitle: String, symbol: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .center, spacing: 13) {
            GlassIcon(symbol: symbol, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            actions()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 86)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                HStack(spacing: 4) {
                    ForEach(ProfileInspectorTab.allCases) { section in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { tab = section }
                        } label: {
                            Text(section.rawValue)
                                .font(.system(size: 11, weight: tab == section ?
                                              .semibold : .regular))
                                .foregroundStyle(tab == section ?
                                                 Color.white : Color.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                                .background {
                                    if tab == section {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(GlassPalette.blue)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Color.white.opacity(0.27),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.62), lineWidth: 1)
                }

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
            editorRow("类别") {
                TextField("分组名称", text: $draftGroup)
                    .textFieldStyle(.roundedBorder)
            }
            editorRow("配置文件") {
                Label(profile.sourceFilename, systemImage: "doc.text")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                Button("编辑文件…") {
                    Task {
                        if let text = await model.editSource(for: profile) {
                            editorText = text
                            showingEditor = true
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.connected || model.connecting)
            }
            editorRow("备注") {
                TextField("添加备注信息", text: $draftNotes)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("创建时间：\(profile.importedAt, format: .dateTime.year().month().day())")
                    Text("文件类型：OpenVPN")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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
        .padding(10)
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
