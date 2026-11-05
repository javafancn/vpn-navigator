import SwiftUI
import AppKit
import VPNNavigatorCore

/// Native menu content; macOS owns its material, sizing, selection and appearance.
/// Presentation refreshes never start probes or helper requests.
struct GlassMenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private func showMainWindow() {
        MainWindowPresentation.shared.show { openWindow(id: "main") }
    }
    private var connectionToggle: Binding<Bool> {
        Binding(get: { model.connected || model.connecting }, set: { enabled in
            Task {
                if enabled { await model.connectSelected() }
                else { await model.disconnect() }
            }
        })
    }
    private var connectionDisabled: Bool {
        model.stopping ||
        (model.busy && !model.connecting && !model.connected && !model.firewallRecoveryRequired) ||
        (!model.connected && model.selected == nil) ||
        (!model.connected && !model.connecting && (model.profileTransferInProgress || model.showingImportReport))
    }
    private var routingProfileID: UUID? {
        model.connected ? model.activeProfileID : model.selectedID
    }

    var body: some View {
        Group {
            Section("VPN Navigator") {
                Text(model.overviewRecoveryNeeded ? L10n.text("需要恢复网络") : model.menuStatusTitle)
                if let profile = model.activeProfile ?? model.selected {
                    Text(profile.name)
                }
                Toggle(L10n.text("VPN 连接"), isOn: connectionToggle)
                    .disabled(connectionDisabled)
            }

            Section(L10n.text("实时流量")) {
                trafficSummary
            }

            Menu(L10n.text("路由模式")) {
                ForEach([RoutingMode.chinaDirect, .fullVPN]) { mode in
                    Toggle(mode.title, isOn: Binding(
                        get: { model.displayedRoutingMode(for: routingProfileID) == mode },
                        set: { selected in
                            guard selected else { return }
                            let id = routingProfileID
                            Task { await model.setMode(mode, for: id) }
                        }))
                        .disabled(!model.canSetRoutingMode(mode, for: routingProfileID))
                }
                Divider()
                Text(model.routingModeStatus)
            }

            Menu(L10n.text("智能连接")) {
                Text(model.smartConnection.status)
                Button(L10n.text("智能连接")) { model.smartConnection.connectNow() }
                    .disabled(model.profiles.isEmpty || model.busy || model.stopping)
                if model.smartConnection.preferences.enabled {
                    Button(model.smartConnection.preferences.paused ? L10n.text("恢复自动连接") : L10n.text("暂停自动连接")) {
                        model.smartConnection.togglePause()
                    }
                }
                Divider()
                Button(L10n.text("智能连接设置…")) {
                    showMainWindow()
                    model.showingSmartConnection = true
                }
            }

            Divider()
            Button(L10n.text("打开主窗口")) { showMainWindow() }
            Button(L10n.text("快速打开…")) { model.quickAccess.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button(L10n.text("退出")) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .disabled(model.stopping)
        }
        .environment(\.locale, L10n.locale)
        .onAppear { model.quickAccess.openMainWindow = showMainWindow }
    }

    private var trafficSummary: some View {
        // Read the same fresh observations as the status label. A native menu
        // needs no animation timer or additional network polling.
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let fresh = model.connected && model.menuTraffic.isFresh(at: now, uptime: uptime)
        let speed = fresh ? model.menuTraffic.current(at: now, uptime: uptime) : nil
        return Group {
            Text(L10n.text("下载") + "  " + TunnelSpeedFormat.string(speed?.receivedPerSecond))
            Text(L10n.text("上传") + "  " + TunnelSpeedFormat.string(speed?.sentPerSecond))
            Text(L10n.text("累计接收") + "  " + bytes(fresh ? model.traffic?.receivedBytes : nil))
            Text(L10n.text("累计发送") + "  " + bytes(fresh ? model.traffic?.sentBytes : nil))
        }
    }
    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
