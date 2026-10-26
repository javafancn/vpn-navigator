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
final class WorkspaceCommandRouter: ObservableObject {
    @Published private(set) var available = false
    private weak var window: NSWindow?
    private weak var model: AppModel?
    private weak var navigation: WorkspaceNavigation?
    private var subscriptions: [AnyCancellable] = []
    init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            subscriptions.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                self?.refresh()
                // Sheet/key notifications may precede the final window state.
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            })
        }
    }
    func configure(model: AppModel, navigation: WorkspaceNavigation) {
        self.model = model; self.navigation = navigation; refresh()
    }
    func attach(_ window: NSWindow?) {
        self.window = window
        // Representable updates run during view reconciliation.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    private var mayPerform: Bool {
        guard let window, let model, navigation != nil else { return false }
        return NSApp.isActive && NSApp.keyWindow === window && !model.workspaceNavigationBlocked
    }
    func refresh() { let next = mayPerform; if available != next { available = next } }
    func select(_ tab: WorkspaceTab) { guard mayPerform else { return }; navigation?.select(tab) }
    func search() { guard mayPerform else { return }; navigation?.searchProfiles() }
    func help() { guard mayPerform else { return }; model?.showingKeyboardHelp = true }
}

/// Observes only this view's own NSWindow; never monitors or intercepts keys.
@MainActor
struct WorkspaceCommandWindowBridge: NSViewRepresentable {
    let router: WorkspaceCommandRouter
    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.onWindow = { [weak router] window in router?.attach(window) }
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: WindowProbe, context: Context) { router.attach(view.window) }
    final class WindowProbe: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    }
}

@MainActor
struct WorkspaceCommands: Commands {
    @ObservedObject var router: WorkspaceCommandRouter
    var body: some Commands {
        CommandMenu("工作区") {
            ForEach(Array(WorkspaceTab.allCases.enumerated()), id: \.element.id) { index, tab in
                Button(tab.title) { router.select(tab) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(!router.available)
            }
            Divider()
            Button("搜索配置…") { router.search() }
                .keyboardShortcut("f", modifiers: .command).disabled(!router.available)
        }
        CommandGroup(after: .help) {
            Button("键盘与辅助功能…") { router.help() }.disabled(!router.available)
        }
    }
}

struct KeyboardHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("键盘与辅助功能").font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("快捷键仅作用于当前主窗口；打开对话框后，先完成或关闭对话框。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 7) {
                ForEach(Array(WorkspaceTab.allCases.enumerated()), id: \.element.id) { index, tab in
                    shortcut(tab.title, "⌘\(index + 1)")
                }
                Divider()
                shortcut("搜索配置", "⌘F")
                shortcut("导入配置", "⌘O")
                shortcut("快速打开", "⇧⌘P")
                shortcut("搜索后进入配置列表", "Return")
                shortcut("在配置列表内选择", "↑ / ↓")
            }.padding(12).glassCard(cornerRadius: 12)
            Text("在 macOS「系统设置 → 键盘」开启键盘导航后，可用 Tab / ⇧Tab 移动焦点，空格按下按钮。搜索框保留系统文本编辑和中文输入法行为；进入列表只选择配置，不会发起连接。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("界面跟随系统的减少动态效果、降低透明度和增强对比度。VoiceOver 会读取工作区选择、配置收藏及连接状态；密码继续使用安全输入框。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("完成") { dismiss() }.buttonStyle(ReferencePrimaryButton()).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 560).background(GlassAtmosphere())
    }
    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack { Text(title); Spacer(); Text(keys).font(.system(.body, design: .monospaced)) }
            .accessibilityElement(children: .combine)
    }
}
