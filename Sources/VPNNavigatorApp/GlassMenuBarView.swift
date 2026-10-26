import SwiftUI
import AppKit
import VPNNavigatorCore

/// The compact companion to the five workspaces. Values always come from
/// AppModel; no reference throughput or geographic names are substituted.
struct GlassMenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
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
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                BrandMark(size: 38)
                Text("VPN Navigator").font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 0)
                Toggle(L10n.text("VPN 连接"), isOn: connectionToggle)
                    .toggleStyle(.switch).labelsHidden().tint(GlassPalette.blue)
                    .disabled(model.stopping || (model.busy && !model.connecting && !model.connected && !model.firewallRecoveryRequired) || (!model.connected && model.selected == nil) || (!model.connected && !model.connecting && (model.profileTransferInProgress || model.showingImportReport)))
            }
            VStack(alignment: .leading, spacing: 14) {
                Label(model.menuStatusTitle, systemImage: model.menuStatusSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.connected ? .green : GlassPalette.ink.opacity(0.6))
                HStack(spacing: 12) {
                    Image(systemName: "globe").font(.system(size: 32)).foregroundStyle(GlassPalette.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.activeProfile?.name ?? model.selected?.name ?? L10n.text("尚未选择配置"))
                            .font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Text(model.activeProfile?.sourceFilename ?? model.selected?.sourceFilename ?? L10n.text("导入 .ovpn 后即可连接"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 5) {
                        Label(bytes(model.traffic?.receivedBytes), systemImage: "arrow.down")
                        Label(bytes(model.traffic?.sentBytes), systemImage: "arrow.up")
                    }.font(.system(size: 12)).foregroundStyle(GlassPalette.blue)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 15)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.routingModeStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach([RoutingMode.chinaDirect, .fullVPN]) { mode in
                        let id = model.connected ? model.activeProfileID : model.selectedID
                        Button { Task { await model.setMode(mode, for: id) } } label: {
                            Label(mode.title, systemImage: model.displayedRoutingMode(for: id) == mode ? "checkmark.circle.fill" : "circle")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(ReferenceSecondaryButton())
                            .tint(model.displayedRoutingMode(for: id) == mode ? GlassPalette.blue : .secondary)
                            .disabled(!model.canSetRoutingMode(mode, for: id))
                    }
                }
            }.padding(12).glassCard(cornerRadius: 15)
            VStack(spacing: 0) {
                Button { model.smartConnection.connectNow() } label: { menuRow(L10n.text("智能连接"), symbol: "bolt.shield") }
                    .buttonStyle(ReferenceQuietButton()).disabled(model.profiles.isEmpty || model.busy || model.stopping)
                if model.smartConnection.preferences.enabled {
                    Button { model.smartConnection.togglePause() } label: {
                        menuRow(model.smartConnection.preferences.paused ? L10n.text("恢复自动连接") : L10n.text("暂停自动连接"), symbol: model.smartConnection.preferences.paused ? "play.circle" : "pause.circle")
                    }.buttonStyle(ReferenceQuietButton())
                }
                Text(model.smartConnection.status).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Button { openWindow(id: "main"); model.showingSmartConnection = true; NSApp.activate(ignoringOtherApps: true) } label: { menuRow(L10n.text("智能连接设置…"), symbol: "bell.badge") }
                    .buttonStyle(ReferenceQuietButton())
                Button { model.quickAccess.toggle() } label: { menuRow(L10n.text("快速打开…"), symbol: "magnifyingglass") }
                    .buttonStyle(ReferenceQuietButton())
                Divider().opacity(0.2)
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { menuRow(L10n.text("打开主窗口"), symbol: "macwindow") }
                .buttonStyle(ReferenceQuietButton())
                Divider().opacity(0.2)
                Button {
                    NSApp.terminate(nil)
                } label: { menuRow(L10n.text("退出"), symbol: "power") }
                .buttonStyle(ReferenceQuietButton()).disabled(model.stopping)
            }
            .padding(.horizontal, 12).glassCard(cornerRadius: 15)
        }
        .padding(12).frame(width: 360)
        .background(GlassAtmosphere()).preferredColorScheme(.light)
    }
    private func menuRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 24)
            Text(title).font(.system(size: 16))
            Spacer()
        }.foregroundStyle(GlassPalette.ink).frame(height: 45).contentShape(Rectangle())
    }
}
