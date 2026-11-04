import SwiftUI
import AppKit
import VPNNavigatorCore

/// A compact companion to the workspace, using the same session and routing
/// actions. Presentation refreshes never start probes or helper requests.
struct GlassMenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private func showMainWindow() {
        MainWindowPresentation.shared.show { openWindow(id: "main") }
    }
    private var statusColor: Color {
        if model.overviewRecoveryNeeded || model.sessionState == .failed { return .orange }
        if model.connected { return .green }
        return model.connecting || model.stopping ? GlassPalette.blue : .secondary
    }
    private var connectionToggle: Binding<Bool> {
        Binding(get: { model.connected || model.connecting }, set: { enabled in
            Task {
                if enabled { await model.connectSelected() }
                else { await model.disconnect() }
            }
        })
    }
    var body: some View {
        VStack(spacing: 14) {
            header
            connectionCard
            routingSection
            Divider().opacity(0.45)
            smartConnectionSection
            Divider().opacity(0.45)
            VStack(spacing: 2) {
                Button { showMainWindow() } label: {
                    menuRow(L10n.text("打开主窗口"), symbol: "macwindow")
                }
                Button { model.quickAccess.toggle() } label: {
                    menuRow(L10n.text("快速打开…"), symbol: "magnifyingglass", shortcut: "⇧⌘P")
                }
            }.buttonStyle(MenuBarRowStyle())
            Divider().opacity(0.45)
            Button { NSApp.terminate(nil) } label: {
                menuRow(L10n.text("退出"), symbol: "power")
            }
            .buttonStyle(MenuBarRowStyle()).disabled(model.stopping)
        }
        .padding(16).frame(width: 344)
        .foregroundStyle(GlassPalette.ink)
        .background(GlassAtmosphere(backdrop: .popover))
        .preferredColorScheme(.light)
        .environment(\.locale, L10n.locale)
        .onAppear { model.quickAccess.openMainWindow = showMainWindow }
    }
    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("VPN Navigator").font(.system(size: 15, weight: .semibold))
                Label(model.overviewRecoveryNeeded ? L10n.text("需要恢复网络") : model.menuStatusTitle,
                    systemImage: model.overviewRecoveryNeeded ? "exclamationmark.shield" : model.menuStatusSymbol)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle(L10n.text("VPN 连接"), isOn: connectionToggle)
                .toggleStyle(.switch).labelsHidden().tint(GlassPalette.blue).controlSize(.small)
                .disabled(model.stopping || (model.busy && !model.connecting && !model.connected && !model.firewallRecoveryRequired) || (!model.connected && model.selected == nil) || (!model.connected && !model.connecting && (model.profileTransferInProgress || model.showingImportReport)))
        }
    }
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 19, weight: .light)).foregroundStyle(GlassPalette.blue)
                    .frame(width: 34, height: 34)
                    .background(GlassPalette.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.activeProfile?.name ?? model.selected?.name ?? L10n.text("尚未选择配置"))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(model.activeProfile?.sourceFilename ?? model.selected?.sourceFilename ?? L10n.text("导入 .ovpn 后即可连接"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            Divider().opacity(0.4)
            TimelineView(.animation(minimumInterval: 1, paused: !model.connected)) { _ in
                let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
                let fresh = model.connected && model.menuTraffic.isFresh(at: now, uptime: uptime)
                let speed = fresh ? model.menuTraffic.current(at: now, uptime: uptime) : nil
                HStack(spacing: 14) {
                    trafficColumn(L10n.text("下载"), symbol: "arrow.down", rate: speed?.receivedPerSecond,
                        totalTitle: L10n.text("累计接收"), total: fresh ? model.traffic?.receivedBytes : nil, color: GlassPalette.blue)
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 46)
                    trafficColumn(L10n.text("上传"), symbol: "arrow.up", rate: speed?.sentPerSecond,
                        totalTitle: L10n.text("累计发送"), total: fresh ? model.traffic?.sentBytes : nil, color: .teal)
                }
            }
        }
        .padding(14).glassCard(cornerRadius: 14)
    }
    private func trafficColumn(_ title: String, symbol: String, rate: Double?, totalTitle: String, total: UInt64?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            Text(TunnelSpeedFormat.string(rate)).font(.system(size: 19, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(totalTitle + " " + bytes(total)).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("路由模式")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach([RoutingMode.chinaDirect, .fullVPN]) { mode in
                    let id = model.connected ? model.activeProfileID : model.selectedID
                    let selected = model.displayedRoutingMode(for: id) == mode
                    Button { Task { await model.setMode(mode, for: id) } } label: {
                        Label(mode.title, systemImage: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .frame(maxWidth: .infinity).frame(minHeight: 32)
                    }
                    .buttonStyle(MenuBarRowStyle(selected: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .disabled(!model.canSetRoutingMode(mode, for: id))
                }
            }
            Text(model.routingModeStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var smartConnectionSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { model.smartConnection.connectNow() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.shield").font(.system(size: 16)).frame(width: 18)
                            .foregroundStyle(GlassPalette.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("智能连接")).font(.system(size: 13, weight: .medium))
                            Text(model.smartConnection.status).font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 3)
                }
                .disabled(model.profiles.isEmpty || model.busy || model.stopping)
                Button { showMainWindow(); model.showingSmartConnection = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 28, height: 32)
                }
                .help(L10n.text("智能连接设置…")).accessibilityLabel(L10n.text("智能连接设置…"))
            }
            if model.smartConnection.preferences.enabled {
                Button { model.smartConnection.togglePause() } label: {
                    menuRow(model.smartConnection.preferences.paused ? L10n.text("恢复自动连接") : L10n.text("暂停自动连接"),
                        symbol: model.smartConnection.preferences.paused ? "play.circle" : "pause.circle")
                }
            }
        }.buttonStyle(MenuBarRowStyle())
    }
    private func menuRow(_ title: String, symbol: String, shortcut: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 4)
            if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }.frame(minHeight: 28).contentShape(Rectangle())
    }
}

private struct MenuBarRowStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        MenuBarRowBody(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }
}

private struct MenuBarRowBody<Label: View>: View {
    let label: Label
    let selected: Bool
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let highContrast = GlassAccessibility.increasedContrast(contrast)
        label.padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(selected ? GlassPalette.blue : GlassPalette.ink)
            .background(shape.fill(selected ? GlassPalette.blue.opacity(highContrast ? 0.18 : 0.10) :
                Color.primary.opacity(enabled && (hovered || pressed) ? (pressed ? 0.09 : 0.05) : 0)))
            .overlay(shape.strokeBorder(focused ? GlassPalette.blue : highContrast ? Color.primary.opacity(0.5) :
                selected ? GlassPalette.blue.opacity(0.22) : .clear, lineWidth: focused ? 2 : 0.75)
                .allowsHitTesting(false))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(GlassMotion.feedback(reduceMotion), value: hovered)
            .animation(GlassMotion.feedback(reduceMotion), value: pressed)
    }
}
