import SwiftUI
import AppKit
import VPNNavigatorCore

/// A native frosted menubar window, not simulated network or speed data.
struct GlassMenuBarView: View {
    @EnvironmentObject private var model: AppModel

    private func bytes(_ count: UInt64?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                BrandMark(size: 39)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN Navigator").font(.system(size: 13, weight: .bold))
                    Text("快速连接与会话状态")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.connected ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
            }
            .padding(.bottom, 3)

            HStack(spacing: 9) {
                Image(systemName: model.connected ? "checkmark.shield.fill" : "network")
                    .foregroundStyle(model.connected ? Color.green : Color.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.connected ? "VPN 已连接" :
                         model.connecting ? "正在连接" : "VPN 未连接")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.activeProfile?.name ?? model.selected?.name ?? "尚未选择配置")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(11)
            .glassCard(cornerRadius: 12)

            HStack(spacing: 10) {
                statistic("累计接收", bytes(model.traffic?.receivedBytes),
                          symbol: "arrow.down.circle")
                statistic("累计发送", bytes(model.traffic?.sentBytes),
                          symbol: "arrow.up.circle")
            }

            Button {
                Task {
                    if model.connected || model.connecting {
                        await model.disconnect()
                    } else {
                        await model.connectSelected()
                    }
                }
            } label: {
                Label(model.connected || model.connecting ?
                      "断开 VPN" : "连接所选配置",
                      systemImage: model.connected || model.connecting ? "stop.circle" : "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || (!model.connected && !model.connecting && model.selected == nil))
            Divider()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.contains("VPN Navigator") &&
                                                              !$0.isKind(of: NSPanel.self) }) {
                    window.makeKeyAndOrderFront(nil)
                }
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
            }
            .buttonStyle(.plain)
            Button {
                Task { await model.refreshRules() }
            } label: {
                Label("更新中国 IPv4 规则", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            Text("Alpha · Kill Switch 尚未启用")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(15)
        .frame(width: 286)
        .background(.regularMaterial)
    }

    private func statistic(_ title: String, _ value: String,
                           symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .glassCard(cornerRadius: 10)
    }
}
