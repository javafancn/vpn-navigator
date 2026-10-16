import SwiftUI
import AppKit
import VPNNavigatorCore

/// Compact macOS popover, matching the reference's native glass appearance.
/// Only displays measured traffic; the reference's demo IP and speeds are
/// intentionally not treated as live network data.
struct GlassMenuBarView: View {
    @EnvironmentObject private var model: AppModel

    private func bytes(_ count: UInt64?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: count), countStyle: .file)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandMark(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("VPN Navigator")
                        .font(.system(size: 13, weight: .bold))
                    Text("快速连接与会话状态")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("VPN 连接", isOn: connectionToggle)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(GlassPalette.blue)
                    .disabled(model.busy || model.connecting ||
                              (!model.connected && model.selected == nil))
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: model.connected ?
                          "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(model.connected ? Color.green : Color.secondary)
                    Text(model.connected ? "已连接" :
                         model.connecting ? "正在连接" : "未连接")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.connected ? Color.green : Color.primary)
                    if model.connected {
                        Text("· 会话运行中")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
                HStack(spacing: 9) {
                    GlassIcon(symbol: "globe.americas.fill", size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.activeProfile?.name ??
                             model.selected?.name ?? "尚未选择配置")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(model.activeProfile?.sourceFilename ??
                             model.selected?.sourceFilename ?? "导入 .ovpn 后即可连接")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Divider().opacity(0.35)
                HStack(spacing: 9) {
                    statistic("累计接收", bytes(model.traffic?.receivedBytes),
                              symbol: "arrow.down")
                    Spacer()
                    statistic("累计发送", bytes(model.traffic?.sentBytes),
                              symbol: "arrow.up")
                }
            }
            .padding(12)
            .glassCard(cornerRadius: 14, active: true)

            VStack(spacing: 0) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: {
                        $0.title.contains("VPN Navigator") &&
                        !$0.isKind(of: NSPanel.self)
                    }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                } label: {
                    menuRow("打开主窗口", symbol: "macwindow")
                }
                .buttonStyle(.plain)
                Divider().opacity(0.38)
                Button {
                    Task { await model.refreshRules() }
                } label: {
                    menuRow("更新中国 IPv4 规则", symbol: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
            .padding(.horizontal, 5)
            Text("Alpha · PF Kill Switch 尚未启用")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
        }
        .padding(14)
        .frame(width: 292)
        .background(.regularMaterial)
    }

    private func statistic(_ title: String, _ value: String,
                           symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(GlassPalette.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
        }
    }

    private func menuRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 19)
            Text(title)
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
