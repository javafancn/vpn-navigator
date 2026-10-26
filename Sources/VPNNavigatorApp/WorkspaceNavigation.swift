import VPNNavigatorCore
import SwiftUI
import AppKit
import Combine

/// Window-local presentation only. Navigation never starts or changes a tunnel.
@MainActor
final class WorkspaceNavigation: ObservableObject {
    @Published var tab: WorkspaceTab
    @Published private(set) var searchRequest: UUID?
    init(tab: WorkspaceTab = .overview) { self.tab = tab }
    func select(_ tab: WorkspaceTab) { searchRequest = nil; self.tab = tab }
    func searchProfiles() { tab = .profiles; searchRequest = UUID() }
}

/// Explicit native-window ownership also works before any SwiftUI field has
/// focus. Menu actions recheck ownership at execution, not just validation.
@MainActor
final class WorkspaceCommandRouter: NSObject, ObservableObject {
    @Published private(set) var available = false
    private weak var window: NSWindow?
    private weak var model: AppModel?
    private weak var navigation: WorkspaceNavigation?
    private var subscriptions: [AnyCancellable] = []
    private var refreshScheduled = false
    private let menuID = NSUserInterfaceItemIdentifier("com.javafancn.vpnnav.workspace")
    private let helpID = NSUserInterfaceItemIdentifier("com.javafancn.vpnnav.keyboard-help")
    private weak var menuRoot: NSMenu?
    private var workspaceMenu: NSMenu?
    private weak var helpItem: NSMenuItem?
    override init() {
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            subscriptions.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in self?.scheduleRefresh() })
        }
        // SwiftUI can replace the complete main menu after constructing its
        // items. Item notifications alone may run before that root is installed.
        // Reconcile after AppKit updates, only when ownership actually changed.
        subscriptions.append(NotificationCenter.default.publisher(for: NSApplication.didUpdateNotification).sink { [weak self] _ in
            guard let self, self.model != nil, let root = NSApp.mainMenu, root.numberOfItems > 0,
                  self.menuRoot !== root || !root.items.contains(where: { $0.identifier == self.menuID }) else { return }
            self.scheduleRefresh()
        })
    }
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }; refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.refreshScheduled = false; self.refresh()
        }
    }
    func configure(model: AppModel, navigation: WorkspaceNavigation) {
        self.model = model; self.navigation = navigation; refresh()
    }
    func attach(_ window: NSWindow?) {
        self.window = window
        // Representable updates run during view reconciliation.
        scheduleRefresh()
    }
    private var mayPerform: Bool {
        guard let window, let model, navigation != nil else { return false }
        return NSApp.isActive && NSApp.keyWindow === window && !model.workspaceNavigationBlocked
    }
    func selfTestState() -> String {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { return "disabled" }
        return "attached=\(window != nil), model=\(model != nil), navigation=\(navigation != nil), active=\(NSApp.isActive), keyMatches=\(window === NSApp.keyWindow), blocked=\(model?.workspaceNavigationBlocked ?? true), available=\(available), menuRootMatches=\(menuRoot === NSApp.mainMenu), menuTitles=\(NSApp.mainMenu?.items.map(\.title) ?? []), language=\(L10n.language.rawValue)"
    }
    func refresh() {
        installMenusIfNeeded()
        let next = mayPerform
        if available != next { available = next }
        for item in (workspaceMenu?.items ?? []) + [helpItem].compactMap({ $0 }) where !item.isSeparatorItem {
            if item.isEnabled != next { item.isEnabled = next }
        }
    }
    private func installMenusIfNeeded() {
        guard model != nil, let root = NSApp.mainMenu, root.numberOfItems > 0 else { return }
        if menuRoot !== root {
            menuRoot = root
            workspaceMenu = root.items.first(where: { $0.identifier == menuID })?.submenu
            helpItem = nil
        }
        if workspaceMenu == nil {
            let menu = NSMenu(title: L10n.text("工作区")); menu.autoenablesItems = false
            for (index, tab) in WorkspaceTab.allCases.enumerated() {
                let item = NSMenuItem(title: tab.title, action: #selector(selectFromMenu(_:)), keyEquivalent: String(index + 1))
                item.target = self; item.keyEquivalentModifierMask = .command; item.representedObject = tab.rawValue
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let search = NSMenuItem(title: L10n.text("搜索配置…"), action: #selector(searchFromMenu(_:)), keyEquivalent: "f")
            search.target = self; search.keyEquivalentModifierMask = .command; menu.addItem(search)
            workspaceMenu = menu
        }
        if let existing = root.items.first(where: { $0.identifier == menuID }) {
            if existing.submenu !== workspaceMenu { existing.submenu = workspaceMenu }
        } else {
            let item = NSMenuItem(title: L10n.text("工作区"), action: nil, keyEquivalent: "")
            item.identifier = menuID; item.submenu = workspaceMenu
            let index = root.items.firstIndex(where: { $0.submenu != nil && $0.submenu === NSApp.windowsMenu }) ?? max(1, root.numberOfItems - 1)
            root.insertItem(item, at: min(index, root.numberOfItems))
        }
        var help = root.items.compactMap(\.submenu).first { $0 === NSApp.helpMenu || ["帮助", "Help"].contains($0.title) }
        if help == nil {
            let menu = NSMenu(title: L10n.text("帮助"))
            let item = NSMenuItem(title: L10n.text("帮助"), action: nil, keyEquivalent: ""); item.submenu = menu
            root.addItem(item); NSApp.helpMenu = menu; help = menu
        }
        if let help {
            if let existing = help.items.first(where: { $0.identifier == helpID }) { helpItem = existing }
            else {
                let item = NSMenuItem(title: L10n.text("键盘与辅助功能…"), action: #selector(helpFromMenu(_:)), keyEquivalent: "")
                item.identifier = helpID; item.target = self; help.addItem(item); helpItem = item
            }
        }
    }
    // Objective-C targets keep native menu validation independent of SwiftUI
    // scene focus. No event monitor or key interception is installed.
    @objc private func selectFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tab = WorkspaceTab(rawValue: raw) else { return }
        select(tab)
    }
    @objc private func searchFromMenu(_ sender: NSMenuItem) { search() }
    @objc private func helpFromMenu(_ sender: NSMenuItem) { help() }
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { mayPerform }

    func select(_ tab: WorkspaceTab) { guard mayPerform else { return }; navigation?.select(tab) }
    func search() { guard mayPerform else { return }; navigation?.searchProfiles() }
    func help() { guard mayPerform else { return }; model?.showingKeyboardHelp = true }
}

struct KeyboardHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("键盘与辅助功能")).font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text(L10n.text("快捷键仅作用于当前主窗口；打开对话框后，先完成或关闭对话框。"))
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 7) {
                ForEach(Array(WorkspaceTab.allCases.enumerated()), id: \.element.id) { index, tab in
                    shortcut(tab.title, "⌘\(index + 1)")
                }
                Divider()
                shortcut(L10n.text("搜索配置"), "⌘F")
                shortcut(L10n.text("导入配置"), "⌘O")
                shortcut(L10n.text("快速打开"), "⇧⌘P")
                shortcut(L10n.text("搜索后进入配置列表"), "Return")
                shortcut(L10n.text("在配置列表内选择"), "↑ / ↓")
            }.padding(12).glassCard(cornerRadius: 12)
            Text(L10n.text("在 macOS「系统设置 → 键盘」开启键盘导航后，可用 Tab / ⇧Tab 移动焦点，空格按下按钮。搜索框保留系统文本编辑和中文输入法行为；进入列表只选择配置，不会发起连接。"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("界面跟随系统的减少动态效果、降低透明度和增强对比度。VoiceOver 会读取工作区选择、配置收藏及连接状态；密码继续使用安全输入框。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button(L10n.text("完成")) { dismiss() }.buttonStyle(ReferencePrimaryButton()).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 560).background(GlassAtmosphere())
    }
    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack { Text(title); Spacer(); Text(keys).font(.system(.body, design: .monospaced)) }
            .accessibilityElement(children: .combine)
    }
}
