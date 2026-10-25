import AppKit
import Combine
import SwiftUI
import VPNNavigatorCore

@MainActor
final class QuickAccessState: ObservableObject {
    @Published var query = ""
    @Published var selectedID: UUID?
    @Published var pendingSwitchID: UUID?
    var expectedSession: QuickAccessSession?
}

@MainActor
final class QuickAccessCoordinator: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    let state = QuickAccessState()
    private let hotKey = GlobalQuickAccessHotKey()
    private var subscription: AnyCancellable?
    private(set) var panel: QuickAccessPanel?
    var openMainWindow: () -> Void = { NSApp.activate(ignoringOtherApps: true) }

    init(model: AppModel) {
        self.model = model
        super.init()
        hotKey.onPressed = { [weak self] in self?.toggle() }
        subscription = model.$quickAccessShortcut.removeDuplicates().sink { [weak self] in self?.register($0) }
    }
    private var matches: [VPNProfile] {
        QuickProfileSearch.results(model?.profiles ?? [], query: state.query)
    }
    private func register(_ shortcut: QuickAccessShortcut) {
        do {
            try hotKey.register(shortcut)
            model?.quickAccessShortcutStatus = shortcut == .disabled ? "全局快捷键已关闭" : "已启用 " + shortcut.title
        } catch { model?.quickAccessShortcutStatus = error.localizedDescription }
    }
    func retryShortcut() { if let model { register(model.quickAccessShortcut) } }
    func toggle() { if panel?.isVisible == true { hide() } else { show() } }
    func show() {
        guard let model else { return }
        guard NSApp.modalWindow == nil, model.profileHealthTarget == nil, !model.showingProfileBackup, !model.showingAccountCredentials,
              model.authenticationChallenge == nil, !model.showingSetup,
              !model.showingMaintenance, !model.maintenanceInProgress,
              !model.showingImportReport, !model.profileTransferInProgress,
              !model.backgroundServicesBusy else { openMainWindow(); return }
        state.query = ""
        state.pendingSwitchID = nil
        state.expectedSession = nil
        state.selectedID = matches.contains(where: { $0.id == model.selectedID }) ? model.selectedID : matches.first?.id
        if panel == nil {
            let window = QuickAccessPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "VPN Navigator Quick Access"
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            window.delegate = self
            window.onKey = { [weak self] in self?.handleKey($0) ?? false }
            window.contentView = NSHostingView(rootView: QuickAccessView(state: state,
                onSelect: { [weak self] id in self?.select(id) },
                onActivate: { [weak self] in self?.activateSelection() },
                onConfirm: { [weak self] in self?.confirmSwitch() },
                onCancel: { [weak self] in self?.cancelSwitch() },
                onNormalize: { [weak self] in self?.normalizeSelection() },
                onOpenMain: { [weak self] in self?.hide(); self?.openMainWindow() })
                .environmentObject(model))
            panel = window
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
           let panel {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                y: visible.minY + (visible.height - panel.frame.height) * 0.65))
        }
        panel?.makeKeyAndOrderFront(nil)
    }
    func hide() {
        panel?.orderOut(nil)
        state.query = ""
        cancelSwitch()
    }
    func select(_ id: UUID) {
        guard matches.contains(where: { $0.id == id }) else { return }
        state.selectedID = id
        cancelSwitch()
    }
    func normalizeSelection() {
        if state.query.count > 256 { state.query = String(state.query.prefix(256)) }
        if !matches.contains(where: { $0.id == state.selectedID }) { state.selectedID = matches.first?.id }
        cancelSwitch()
    }
    func handleKey(_ code: UInt16) -> Bool {
        switch code {
        case 53:
            if state.pendingSwitchID != nil { cancelSwitch() } else { hide() }
        case 125, 126:
            state.selectedID = QuickProfileSearch.movedSelection(state.selectedID,
                in: matches.map(\.id), offset: code == 125 ? 1 : -1)
            cancelSwitch()
        case 36, 76:
            // Holding Return must never confirm a tunnel switch.
            if state.pendingSwitchID == nil { activateSelection() }
        default: return false
        }
        return true
    }
    func activateSelection() {
        guard let model, let id = state.selectedID, matches.contains(where: { $0.id == id }) else { return }
        switch model.quickAccessAction(for: id) {
        case .blocked: return
        case .openMain: hide(); openMainWindow()
        case .connect: perform(id, replacing: nil)
        case .requestSwitch:
            state.expectedSession = model.quickAccessSession
            state.pendingSwitchID = id
        }
    }
    func confirmSwitch() {
        guard let model, let id = state.pendingSwitchID, let previous = state.expectedSession,
              model.quickAccessSession == previous, model.quickAccessAction(for: id) == .requestSwitch else {
            cancelSwitch(); return
        }
        perform(id, replacing: previous)
    }
    func cancelSwitch() { state.pendingSwitchID = nil; state.expectedSession = nil }
    private func perform(_ id: UUID, replacing previous: QuickAccessSession?) {
        guard let model else { return }
        hide()
        openMainWindow()
        Task { await model.activateQuickProfile(id, replacing: previous) }
    }
    func windowDidResignKey(_ notification: Notification) {
        if panel?.isVisible == true { hide() }
    }
    func shutdown() {
        subscription?.cancel()
        hotKey.unregister()
        hide()
        panel?.contentView = nil
        panel = nil
    }
}

final class QuickAccessPanel: NSPanel {
    var onKey: ((UInt16) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           !((firstResponder as? NSTextView)?.hasMarkedText() ?? false) {
            // Return belongs to the focused footer button when tabbing;
            // never replace its action with the selected profile's action.
            if event.keyCode == 53 {
                if onKey?(event.keyCode) == true { return }
            } else if firstResponder is NSTextView {
                if event.isARepeat, [36, 76].contains(event.keyCode) { return }
                if onKey?(event.keyCode) == true { return }
            }
        }
        super.sendEvent(event)
    }
}
