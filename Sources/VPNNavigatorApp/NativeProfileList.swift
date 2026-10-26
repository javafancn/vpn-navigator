import AppKit
import Combine
import SwiftUI
import VPNNavigatorCore

/// NSTableView owns the responder and arrow navigation; SwiftUI supplies only
/// the glass row content. No key monitor, input interception or global hook.
@MainActor
final class ProfileListKeyboard: ObservableObject {
    @Published private(set) var focused = false
    weak var table: NSTableView?
    private var subscriptions: [AnyCancellable] = []
    init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            subscriptions.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in self?.refresh() })
        }
    }
    func focus() {
        // Let the search field finish its submit/editing callback first.
        DispatchQueue.main.async { [weak self] in
            guard let table = self?.table else { return }
            table.window?.makeFirstResponder(table); self?.refresh()
        }
    }
    func refresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let next = self.table.map { $0.window?.firstResponder === $0 && $0.window?.isKeyWindow == true } ?? false
            if self.focused != next { self.focused = next }
        }
    }
}

@MainActor
struct NativeProfileList: NSViewRepresentable {
    let profiles: [VPNProfile]
    @Binding var selection: UUID?
    let keyboard: ProfileListKeyboard
    let row: (VPNProfile) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        let table = ProfileTable()
        table.headerView = nil; table.backgroundColor = .clear; table.style = .plain
        table.selectionHighlightStyle = .none; table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.rowHeight = 60; table.intercellSpacing = NSSize(width: 0, height: 5)
        table.usesAutomaticRowHeights = false; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: .init("profile")); column.minWidth = 0; column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.onFocus = { [weak keyboard] in keyboard?.refresh() }
        table.setAccessibilityLabel(L10n.text("配置列表"))
        scroll.documentView = table; keyboard.table = table
        update(scroll, coordinator: context.coordinator)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { update(scroll, coordinator: context.coordinator) }
    private func update(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let dataChanged = coordinator.profiles != profiles
        coordinator.applying = true
        coordinator.profiles = profiles; coordinator.selection = $selection; coordinator.row = row
        if dataChanged { table.reloadData() }
        // Refresh visible SwiftUI cells without recreating the native responder.
        for index in 0..<profiles.count {
            if let host = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSHostingView<AnyView> {
                host.rootView = row(profiles[index])
            }
        }
        let target = profiles.firstIndex { $0.id == selection }
        if let target {
            if table.selectedRow != target { table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false) }
            if keyboard.focused { table.scrollRowToVisible(target) }
        } else if table.selectedRow != -1 {
            // A filtered-out UUID remains the model's selection. Deselecting
            // native rows here must never erase that hidden selection.
            table.deselectAll(nil)
        }
        coordinator.applying = false
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let table = scroll.documentView as? ProfileTable else { return }
        table.onFocus = nil; table.delegate = nil; table.dataSource = nil
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var profiles: [VPNProfile] = []
        var selection: Binding<UUID?>?
        var row: ((VPNProfile) -> AnyView)?
        var applying = false
        func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row index: Int) -> Any? {
            profiles.indices.contains(index) ? profiles[index].name : nil
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard profiles.indices.contains(index), let row else { return nil }
            let id = NSUserInterfaceItemIdentifier("profile-cell")
            if let host = tableView.makeView(withIdentifier: id, owner: nil) as? NSHostingView<AnyView> {
                host.rootView = row(profiles[index]); return host
            }
            let host = NSHostingView(rootView: row(profiles[index])); host.identifier = id
            return host
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table = notification.object as? NSTableView, profiles.indices.contains(table.selectedRow) else { return }
            let id = profiles[table.selectedRow].id
            if selection?.wrappedValue != id { selection?.wrappedValue = id }
        }
    }
    final class ProfileTable: NSTableView {
        var onFocus: (() -> Void)?
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder(); if result { onFocus?() }; return result
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder(); if result { onFocus?() }; return result
        }
    }
}
