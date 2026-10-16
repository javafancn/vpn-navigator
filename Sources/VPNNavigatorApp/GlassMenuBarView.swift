import SwiftUI
import AppKit
import VPNNavigatorCore

/// The compact companion to the five workspaces. Values always come from
/// AppModel; no reference throughput or geographic names are substituted.
struct GlassMenuBarView: View {
    @EnvironmentObject private var model: AppModel

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    private var connectionToggle: Binding<Bool> {
        Binding(get: { model.connected }, set: { enabled in
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
                Toggle("VPN 连接", isOn: connectionToggle)
                    .toggleStyle(.switch).labelsHidden().tint(GlassPalette.blue)
                    .disabled(model.busy || model.connecting || (!model.connected && model.selected == nil))
            }
            VStack(alignment: .leading, spacing: 14) {
                Label(model.connected ? "已连接" : model.connecting ? "正在连接" : "未连接", systemImage: model.connected ? "checkmark.circle.fill" : "circle.dotted")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.connected ? .green : GlassPalette.ink.opacity(0.6))
                HStack(spacing: 12) {
                    Image(systemName: "globe").font(.system(size: 32)).foregroundStyle(GlassPalette.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.activeProfile?.name ?? model.selected?.name ?? "尚未选择配置")
                            .font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Text(model.activeProfile?.sourceFilename ?? model.selected?.sourceFilename ?? "导入 .ovpn 后即可连接")
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
            VStack(spacing: 0) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.title.contains("VPN Navigator") && !$0.isKind(of: NSPanel.self) })?.makeKeyAndOrderFront(nil)
                } label: { menuRow("打开主窗口", symbol: "macwindow") }
                .buttonStyle(.plain)
                Divider().opacity(0.2)
                Button {
                    Task {
                        if model.connected { await model.disconnect() }
                        if !model.connected && !model.connecting { NSApp.terminate(nil) }
                    }
                } label: { menuRow("退出", symbol: "power") }
                .buttonStyle(.plain).disabled(model.connecting || model.busy)
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
