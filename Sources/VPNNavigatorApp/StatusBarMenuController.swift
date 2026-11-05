import AppKit
import Combine
import VPNNavigatorCore

/// Own the native menu independently of SwiftUI's frequently published session
/// and traffic state. A tracking session keeps the same items and submenus.
@MainActor
final class StatusBarMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private weak var model: AppModel?
    private var statusItem: NSStatusItem?
    private var subscription: AnyCancellable?
    private var trafficTimer: AnyCancellable?
    private var tracking = false

    private enum Action {
        case connection(Bool, UUID?)
        case mode(RoutingMode, UUID?)
        case connectNow, pause(Bool), smartSettings, mainWindow, quickAccess, quit
    }

    init(model: AppModel, installsStatusItem: Bool = true) {
        self.model = model
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        if installsStatusItem {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            statusItem = item
            // objectWillChange precedes the property write. Read on the next
            // run-loop turn, and update only the status button, never the menu.
            subscription = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.refreshLabel()
            }
            refreshLabel()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu, !tracking, let model else { return }
        menu.removeAllItems()
        header("VPN Navigator")
        text(model.overviewRecoveryNeeded ? L10n.text("需要恢复网络") : model.menuStatusTitle)
        if let profile = model.activeProfile ?? model.selected { text(profile.name) }
        let connected = model.connected || model.connecting
        item(L10n.text("VPN 连接"), action: .connection(!connected, model.activeProfileID ?? model.selectedID),
             enabled: !connectionDisabled(model), checked: connected)

        menu.addItem(.separator())
        header(L10n.text("实时流量"))
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let fresh = model.connected && model.menuTraffic.isFresh(at: now, uptime: uptime)
        let speed = fresh ? model.menuTraffic.current(at: now, uptime: uptime) : nil
        text(L10n.text("下载") + "  " + TunnelSpeedFormat.string(speed?.receivedPerSecond))
        text(L10n.text("上传") + "  " + TunnelSpeedFormat.string(speed?.sentPerSecond))
        text(L10n.text("累计接收") + "  " + bytes(fresh ? model.traffic?.receivedBytes : nil))
        text(L10n.text("累计发送") + "  " + bytes(fresh ? model.traffic?.sentBytes : nil))

        menu.addItem(.separator())
        let routing = submenu(L10n.text("路由模式"))
        let profileID = model.connected ? model.activeProfileID : model.selectedID
        for mode in [RoutingMode.chinaDirect, .fullVPN] {
            item(mode.title, in: routing, action: .mode(mode, profileID),
                 enabled: model.canSetRoutingMode(mode, for: profileID),
                 checked: model.displayedRoutingMode(for: profileID) == mode)
        }
        routing.addItem(.separator())
        text(model.routingModeStatus, in: routing)

        let smart = submenu(L10n.text("智能连接"))
        text(model.smartConnection.status, in: smart)
        item(L10n.text("智能连接"), in: smart, action: .connectNow,
             enabled: !model.profiles.isEmpty && !model.busy && !model.stopping)
        if model.smartConnection.preferences.enabled {
            let paused = model.smartConnection.preferences.paused
            item(paused ? L10n.text("恢复自动连接") : L10n.text("暂停自动连接"), in: smart, action: .pause(!paused))
        }
        smart.addItem(.separator())
        item(L10n.text("智能连接设置…"), in: smart, action: .smartSettings)

        menu.addItem(.separator())
        item(L10n.text("打开主窗口"), action: .mainWindow)
        item(L10n.text("快速打开…"), action: .quickAccess, key: "p", modifiers: [.command, .shift])
        menu.addItem(.separator())
        item(L10n.text("退出"), action: .quit, enabled: !model.stopping, key: "q")
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { tracking = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        tracking = false
        // Let AppKit finish dispatching the selected item's action first.
        DispatchQueue.main.async { [weak self] in self?.refreshLabel() }
    }

    private func refreshLabel() {
        guard !tracking, let model, let statusItem, let button = statusItem.button else { return }
        let speed = model.connected ? model.menuTraffic.current() : nil
        let download = TunnelSpeedFormat.string(speed?.receivedPerSecond)
        let upload = TunnelSpeedFormat.string(speed?.sentPerSecond)
        let image = AppBranding.statusLabel(download: download, upload: upload, showsTraffic: model.connected)
        if button.image !== image { button.image = image }
        let description = L10n.format("VPN Navigator，{0}。隧道下载 {1}，上传 {2}。", [model.menuStatusTitle, download, upload])
        button.toolTip = description
        button.setAccessibilityLabel(description)
        if model.connected, trafficTimer == nil {
            trafficTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.refreshLabel()
            }
        } else if !model.connected {
            trafficTimer?.cancel(); trafficTimer = nil
        }
    }

    private func connectionDisabled(_ model: AppModel) -> Bool {
        model.stopping ||
        (model.busy && !model.connecting && !model.connected && !model.firewallRecoveryRequired) ||
        (!model.connected && model.selected == nil) ||
        (!model.connected && !model.connecting && (model.profileTransferInProgress || model.showingImportReport))
    }

    @objc private func executeMenuCommand(_ sender: NSMenuItem) {
        guard let model, let action = sender.representedObject as? Action else { return }
        // A menu can remain open across a disconnect, profile change or
        // maintenance transition. Recheck live guards without rebuilding it.
        switch action {
        case let .connection(enabled, profileID):
            Task {
                guard !connectionDisabled(model), enabled != (model.connected || model.connecting),
                      profileID == (model.activeProfileID ?? model.selectedID) else { return }
                if enabled { await model.connectSelected() }
                else { await model.disconnect() }
            }
        case let .mode(mode, profileID):
            guard model.canSetRoutingMode(mode, for: profileID) else { return }
            Task { await model.setMode(mode, for: profileID) }
        case .connectNow:
            guard !model.profiles.isEmpty, !model.busy, !model.stopping else { return }
            model.smartConnection.connectNow()
        case let .pause(paused):
            guard model.smartConnection.preferences.enabled,
                  model.smartConnection.preferences.paused != paused else { return }
            model.smartConnection.togglePause()
        case .smartSettings:
            model.quickAccess.openMainWindow()
            model.showingSmartConnection = true
        case .mainWindow: model.quickAccess.openMainWindow()
        case .quickAccess: model.quickAccess.toggle()
        case .quit:
            guard !model.stopping else { return }
            NSApp.terminate(nil)
        }
    }

    private func header(_ title: String) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        entry.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(entry)
    }

    private func text(_ title: String, in parent: NSMenu? = nil) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        (parent ?? menu).addItem(entry)
    }

    private func submenu(_ title: String) -> NSMenu {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu(title: title)
        child.autoenablesItems = false
        entry.submenu = child
        menu.addItem(entry)
        return child
    }

    private func item(_ title: String, in parent: NSMenu? = nil, action: Action,
                      enabled: Bool = true, checked: Bool = false, key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command) {
        let entry = NSMenuItem(title: title, action: #selector(executeMenuCommand(_:)), keyEquivalent: key)
        entry.target = self
        entry.representedObject = action
        entry.isEnabled = enabled
        entry.state = checked ? .on : .off
        entry.keyEquivalentModifierMask = modifiers
        (parent ?? menu).addItem(entry)
    }

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    func shutdown() {
        subscription?.cancel(); subscription = nil
        trafficTimer?.cancel(); trafficTimer = nil
        menu.cancelTracking()
        menu.delegate = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
