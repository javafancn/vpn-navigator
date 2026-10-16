import SwiftUI
import VPNNavigatorCore

// One native macOS workspace with clear separation between available
// features and previews. Uses system materials on macOS 13+ without
// assuming the macOS 26-only Liquid Glass APIs.
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case overview, profiles, routing, diagnostics, settings
    var id: String { rawValue }
    // Window and sidebar proportions follow the supplied design collage.
    // Content is never expanded into empty full-height cards.
    var referenceSize: CGSize {
        switch self {
        case .overview: return CGSize(width: 990, height: 587)
        case .profiles: return CGSize(width: 990, height: 595)
        case .routing: return CGSize(width: 930, height: 450)
        case .diagnostics: return CGSize(width: 930, height: 470)
        case .settings: return CGSize(width: 860, height: 430)
        }
    }
    var sidebarWidth: CGFloat {
        switch self {
        case .overview, .profiles: return 228
        case .routing, .diagnostics: return 205
        case .settings: return 193
        }
    }
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
                sidebar.frame(width: tab.sidebarWidth)
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
                    .referenceWorkspaceSurface()
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
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
        .frame(minWidth: 810, minHeight: 400)
        .background(ReferenceWindowSizer(size: tab.referenceSize))
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
            .padding(.top, tab == .overview || tab == .profiles ? 37 : 24)
            .padding(.bottom, tab == .overview || tab == .profiles ? 21 : 13)

            if tab != .overview {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { tab = .overview }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 24)
                        Text("个人")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("返回连接总览")
                .padding(.horizontal, 15)
                .padding(.bottom, 9)
            }

            ForEach(tab == .overview ?
                    WorkspaceTab.allCases :
                    WorkspaceTab.allCases.filter { $0 != .overview }) { item in
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
                    .frame(height: 38)
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
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.connected ? Color.green : Color.secondary.opacity(0.7))
                        .frame(width: 7, height: 7)
                    Text("VPN Navigator")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(model.connected ? "已连接 · " + (model.activeProfile?.name ?? "VPN") :
                     model.connecting ? "正在建立连接" : "未连接 · 选择配置后开始")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("macOS 13+ · " +
                    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Alpha"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(GlassSurface.panel.opacity(0.31))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.65), lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .background {
            GlassSurface.sidebar.opacity(0.20)
        }
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
                    .font(.system(size: 25, weight: .bold, design: .rounded))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appearance == .dark ? Color.white.opacity(0.91) : GlassPalette.ink.opacity(0.85))
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
                    .padding(.bottom, 4)

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
                            .background {
                                Circle()
                                    .fill(GlassPalette.cyan.opacity(0.09))
                                    .frame(width: 231, height: 231)
                                    .blur(radius: 26)
                            }
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
                     .frame(height: 288)
                    .glassCard(cornerRadius: 17, active: true)

                    VStack(spacing: 12) {
                        VPNPanel("快速连接", symbol: "slider.horizontal.3", minContentHeight: 166) {
                            HStack(spacing: 9) {
                                Text("配置文件")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 63, alignment: .leading)
                                Menu {
                                    ForEach(model.profiles) { profile in
                                        Button {
                                            model.selectedID = profile.id
                                        } label: {
                                            if model.selectedID == profile.id {
                                                Label(profile.name, systemImage: "checkmark")
                                            } else {
                                                Text(profile.name)
                                            }
                                        }
                                    }
                                } label: {
                                    connectionField(model.selected?.name ?? "请选择配置")
                                }
                                .buttonStyle(.plain)
                                .disabled(model.profiles.isEmpty || model.busy)
                            }
                            HStack(spacing: 9) {
                                Text("路由模式")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 63, alignment: .leading)
                                Menu {
                                    ForEach(RoutingMode.allCases) { mode in
                                        Button {
                                            Task { await model.setMode(mode) }
                                        } label: {
                                            if model.selected?.mode == mode {
                                                Label(mode.rawValue, systemImage: "checkmark")
                                            } else {
                                                Text(mode.rawValue)
                                            }
                                        }
                                    }
                                } label: {
                                    connectionField(model.selected?.mode.rawValue ?? "Original")
                                }
                                .buttonStyle(.plain)
                                .disabled(model.selected == nil || model.busy ||
                                          model.connected || model.connecting)
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
                        VPNPanel("当前连接", symbol: "globe.americas.fill", minContentHeight: 55) {
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
                                if model.connected, let traffic = model.traffic {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Label(formattedBytes(traffic.receivedBytes),
                                              systemImage: "arrow.down")
                                        Label(formattedBytes(traffic.sentBytes),
                                              systemImage: "arrow.up")
                                    }
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(GlassPalette.blue)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 288, alignment: .top)
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
                    .frame(height: 121, alignment: .top)
                    .glassCard(cornerRadius: 15)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, GlassLayout.pageTop)
            .padding(.bottom, 16)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .confirmationDialog("切换 VPN 配置？", isPresented: $confirmSwitch) {
            Button("断开当前连接并切换") { Task { await model.switchToSelected() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("应用将验证旧会话退出，然后连接新配置。")
        }
    }

    private func connectionField(_ value: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(GlassPalette.blue, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(GlassSurface.panel.opacity(0.65),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.white.opacity(0.86), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private func miniStatistic(_ title: String, symbol: String,
                               value: String, samples: [Double] = []) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(GlassPalette.blue)
                    .frame(width: 28, height: 28)
                    .background(GlassPalette.blue.opacity(0.09), in: Circle())
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            TrafficSparkline(samples: samples)
                .frame(height: 27)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 95)
        .padding(12)
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
                                        } else {
                                            Circle()
                                                .fill(Color.secondary.opacity(0.30))
                                                .frame(width: 7, height: 7)
                                        }
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        model.selectedID == profile.id ?
                                          GlassPalette.blue.opacity(0.14) :
                                          Color.clear,
                                        in: RoundedRectangle(cornerRadius: 11))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 11)
                                            .strokeBorder(model.selectedID == profile.id ?
                                                GlassPalette.blue.opacity(0.18) : .clear,
                                                lineWidth: 1)
                                    }
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
                .padding(10)
                .frame(width: 226)
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
        .padding(.top, GlassLayout.pageTop)
        .padding(.bottom, 18)
    }
}

private struct RoutingWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @State private var snapshotToRestore: RuleSnapshot?

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
            VStack(alignment: .leading, spacing: GlassLayout.sectionSpacing) {
                WorkspaceHeading(title: "路由与规则",
                    subtitle: "管理 VPN 路由模式与中国 IPv4 规则",
                    symbol: "point.3.connected.trianglepath.dotted")

                // One continuous two-column glass surface is essential:
                // the reference does not use two independent floating cards.
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("路由模式")
                            .font(.system(size: 14, weight: .bold))
                        ForEach(RoutingMode.allCases) { mode in
                            routeOption(mode)
                        }
                        Text(model.selected.map { "所选配置：\($0.name)" } ??
                             "请先选择配置后再修改路由")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    Rectangle()
                        .fill(Color.white.opacity(0.58))
                        .frame(width: 1)
                        .padding(.vertical, 16)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("中国 IPv4 规则")
                            .font(.system(size: 14, weight: .bold))
                        HStack(alignment: .center, spacing: 13) {
                            GlassIcon(symbol: "globe.asia.australia.fill", size: 52)
                            VStack(alignment: .leading, spacing: 8) {
                                ruleDetail("规则版本", "未提供")
                                ruleDetail("规则来源", "chnroutes2")
                                ruleDetail("规则数量",
                                    model.rules.map { "\($0.routes.count) 条" } ?? "未下载")
                                ruleDetail("历史快照",
                                    model.ruleSnapshots.first.map {
                                        $0.savedAt.formatted(
                                            .dateTime.year().month().day().hour().minute())
                                    } ?? "尚无快照")
                            }
                        }
                        HStack(spacing: 10) {
                            Button("更新规则") { Task { await model.refreshRules() } }
                                .buttonStyle(.borderedProminent)
                                .tint(GlassPalette.blue)
                                .disabled(model.busy)
                            Menu {
                                ForEach(model.ruleSnapshots) { saved in
                                    Button(saved.savedAt.formatted(
                                        .dateTime.year().month().day().hour().minute())) {
                                        snapshotToRestore = saved
                                    }
                                }
                            } label: {
                                Text("历史版本")
                            }
                            .buttonStyle(ReferenceSecondaryButton())
                            .disabled(model.ruleSnapshots.isEmpty || model.busy)
                            .help("选择历史快照以进行确认恢复")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 265, alignment: .topLeading)
                .glassCard(cornerRadius: 16)

                HStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 11) {
                        GlassIcon(symbol: "shield.lefthalf.filled", size: 39)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("IPv6 规则（预览）")
                                .font(.system(size: 12, weight: .semibold))
                            Text(model.ipv6Preview.map {
                                "\($0.routes.count) 个 APNIC 注册前缀 · 仅供查看"
                            } ?? "未下载 · 仅供查看，不修改系统 IPv6 路由")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("刷新") { Task { await model.updateIPv6Preview() } }
                            .buttonStyle(ReferenceSecondaryButton())
                            .disabled(model.busy)
                    }
                    .padding(12)
                    .frame(maxWidth: 430, alignment: .leading)
                    .glassCard(cornerRadius: 14)
                }
            }
            .padding(.horizontal, GlassLayout.pageInset)
            .padding(.top, GlassLayout.pageTop)
            .padding(.bottom, 14)
            .frame(maxWidth: 1100, alignment: .topLeading)
        }
        .confirmationDialog("恢复旧版 IPv4 规则？",
                            isPresented: Binding(
                                get: { snapshotToRestore != nil },
                                set: { if !$0 { snapshotToRestore = nil } }
                            )) {
            if let snapshot = snapshotToRestore {
                Button("确认恢复历史快照") {
                    Task { await model.restoreRuleSnapshot(snapshot.id) }
                    snapshotToRestore = nil
                }
            }
            Button("取消", role: .cancel) { snapshotToRestore = nil }
        } message: {
            Text("恢复会替换当前规则。已有受管连接的网络安全限制仍然适用。")
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
                    .font(.system(size: 19))
                    .foregroundStyle(selected == mode ?
                                     GlassPalette.blue : Color.gray)
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
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 59, alignment: .leading)
            .background(selected == mode ?
                        GlassPalette.blue.opacity(0.13) : Color.white.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected == mode ?
                                  GlassPalette.blue.opacity(0.29) :
                                  Color.white.opacity(0.14), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .font(.system(size: 11))
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
                        HStack(spacing: 8) {
                            statePill(model.helperStatus,
                                      success: helperReady)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

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
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
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
                    subtitle: "VPN Navigator · 版本 \(version) (Build \(build))",
                    symbol: "info.circle.fill") {
                    Menu {
                        Text("macOS 13+")
                        Text("PF Kill Switch 尚未启用")
                        Text("IPv6 分流尚未实现")
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 30)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, GlassLayout.pageTop)
            .padding(.bottom, 20)
            .frame(maxWidth: 1060, alignment: .topLeading)
        }
    }

    private func statePill(_ text: String, success: Bool = false) -> some View {
        HStack(spacing: 5) {
            if success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
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
        .frame(minHeight: 73)
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
    @State private var editingCustomGroup = false
    @State private var editorText = ""
    @State private var showingEditor = false
    @State private var confirmDelete = false
    @State private var history: [ProfileRevision] = []

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.height >= 475 {
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

    private var inspectorContent: some View {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 13) {
                    GlassIcon(symbol: "network.badge.shield.half.filled", size: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
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
                    Menu {
                        Button("导出预览…") { Task { await model.exportPreview() } }
                        Button("删除配置…", role: .destructive) {
                            confirmDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 22, height: 22)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
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
                .referenceSegments()

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
                    Button("保存更改") {
                        Task {
                            await model.updateMetadata(name: draftName, group: draftGroup,
                                                       notes: draftNotes, favorite: draftFavorite)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("导出预览…") { Task { await model.exportPreview() } }
                        .disabled(profile.mode == .chinaDirect && model.rules == nil)
                }
                .font(.system(size: 11))
                .padding(.top, 6)
            }
            .padding(19)
            .frame(minHeight: 405, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 13) {
            editorRow("名称") {
                TextField("配置名称", text: $draftName)
                    .textFieldStyle(.plain)
                    .referenceInput()
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
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 29)
                    .background(Color.white.opacity(0.58),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.white.opacity(0.77), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                    .textFieldStyle(.plain)
                    .referenceInput()
            }
            VStack(alignment: .leading, spacing: 8) {
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
                LabeledContent("文件大小", value: "未读取")
                LabeledContent("配置类型", value: "OpenVPN")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 12))
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
