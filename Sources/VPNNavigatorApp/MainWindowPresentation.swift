import AppKit

/// Observe the real SwiftUI window without replacing its delegate. Only a
/// completed main-window close demotes the app; minimize and Hide keep Dock.
@MainActor
final class MainWindowPresentation: NSObject {
    static let shared = MainWindowPresentation()
    private weak var mainWindow: NSWindow?
    private var closing = false
    private var revision: UInt64 = 0
    private var pendingOpen: UUID?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(willClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    func attach(_ window: NSWindow) {
        guard !(window is NSPanel), mainWindow !== window else { return }
        mainWindow = window; closing = false; pendingOpen = nil; revision &+= 1
    }
    func show(open: () -> Void) {
        revision &+= 1
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if let window = mainWindow, !closing {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if pendingOpen == nil {
            let request = UUID(); pendingOpen = request
            open()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.pendingOpen == request { self?.pendingOpen = nil }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func becameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        closing = false; pendingOpen = nil; revision &+= 1
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }
    @objc private func willClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        closing = true; revision &+= 1
        let expected = revision
        // willClose precedes removal from the screen. Defer the policy change
        // and discard it if the user has already reopened the scene.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.closing, self.revision == expected else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
