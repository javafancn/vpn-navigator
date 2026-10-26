import SwiftUI

/// Window-local presentation only. Navigation never starts or changes a tunnel.
@MainActor
final class WorkspaceNavigation: ObservableObject {
    @Published var tab: WorkspaceTab
    @Published private(set) var searchRequest: UUID?
    init(tab: WorkspaceTab = .overview) { self.tab = tab }
    func select(_ tab: WorkspaceTab) { searchRequest = nil; self.tab = tab }
    func searchProfiles() { tab = .profiles; searchRequest = UUID() }
}

struct WorkspaceCommandActions {
    let select: (WorkspaceTab) -> Void
    let search: () -> Void
    let help: () -> Void
}
private struct WorkspaceCommandsKey: FocusedValueKey {
    typealias Value = WorkspaceCommandActions
}
extension FocusedValues {
    var workspaceCommands: WorkspaceCommandActions? {
        get { self[WorkspaceCommandsKey.self] }
        set { self[WorkspaceCommandsKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceCommands) private var actions
    var body: some Commands {
        CommandMenu("工作区") {
            ForEach(Array(WorkspaceTab.allCases.enumerated()), id: \.element.id) { index, tab in
                Button(tab.title) { actions?.select(tab) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(actions == nil)
            }
            Divider()
            Button("搜索配置…") { actions?.search() }
                .keyboardShortcut("f", modifiers: .command).disabled(actions == nil)
        }
        CommandGroup(after: .help) {
            Button("键盘与辅助功能…") { actions?.help() }.disabled(actions == nil)
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
