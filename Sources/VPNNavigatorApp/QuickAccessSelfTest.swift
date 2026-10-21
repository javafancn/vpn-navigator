import AppKit
import Carbon
import VPNNavigatorCore

@MainActor
enum QuickAccessSelfTest {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        // Allow SwiftUI's initial window to finish appearing before testing
        // key-window ownership. Profiles are never persisted or connected.
        try await Task.sleep(nanoseconds: 300_000_000)
        let model = AppModel()
        let first = VPNProfile(name: "Alpha", sourceFilename: "alpha.ovpn", relativePath: "fixture-only", isFavorite: true)
        let second = VPNProfile(name: "Beta", sourceFilename: "beta.ovpn", relativePath: "fixture-only")
        model.profiles = [first, second]; model.selectedID = first.id
        let coordinator = QuickAccessCoordinator(model: model)
        defer { coordinator.shutdown() }
        coordinator.show()
        guard let panel = coordinator.panel, panel.isVisible, panel.canBecomeKey,
              !panel.canBecomeMain, panel.frame.size == NSSize(width: 560, height: 460),
              panel.styleMask.contains(.nonactivatingPanel), !panel.isOpaque else { throw Failure.check }
        coordinator.show()
        guard coordinator.panel === panel else { throw Failure.check }
        func key(_ code: UInt16) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { throw Failure.check }
            panel.sendEvent(event)
        }
        try key(125)
        guard coordinator.state.selectedID == second.id else { throw Failure.check }
        try key(126)
        guard coordinator.state.selectedID == first.id else { throw Failure.check }
        coordinator.state.query = "ＢＥＴＡ"; coordinator.normalizeSelection()
        guard coordinator.state.selectedID == second.id else { throw Failure.check }
        coordinator.state.query = ""; coordinator.normalizeSelection()
        model.connectionStatus = "connected: fixture only"
        model.activeProfileID = first.id
        coordinator.select(second.id)
        coordinator.activateSelection()
        guard coordinator.state.pendingSwitchID == second.id, model.selectedID == first.id else { throw Failure.check }
        try key(36)
        guard coordinator.state.pendingSwitchID == second.id, model.selectedID == first.id else { throw Failure.check }
        // A stale confirmation must not disconnect a newly active profile.
        model.activeProfileID = second.id
        coordinator.confirmSwitch()
        guard coordinator.state.pendingSwitchID == nil, model.selectedID == first.id else { throw Failure.check }
        coordinator.state.query = "private search"; try key(53)
        guard !panel.isVisible, coordinator.state.query.isEmpty else { throw Failure.check }
        print("PASS: actual native quick panel reuse, keyboard selection, folded search, Escape and stale-switch refusal; no VPN requests.")

        let registrar = GlobalQuickAccessHotKey()
        defer { registrar.unregister() }
        var callbacks = 0
        registrar.onPressed = { callbacks += 1 }
        for shortcut in QuickAccessShortcut.allCases where shortcut != .disabled {
            try registrar.register(shortcut)
            let conflict = GlobalQuickAccessHotKey()
            do {
                try conflict.register(shortcut)
                conflict.unregister()
                throw Failure.collision
            } catch is GlobalQuickAccessHotKey.RegistrationError { /* expected real OS refusal */ }
            var event: EventRef?
            guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                GetCurrentEventTime(), 0, &event) == noErr, let event else { throw Failure.check }
            var identity = registrar.eventID
            let parameter = SetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), UInt32(MemoryLayout<EventHotKeyID>.size), &identity)
            let dispatched = SendEventToEventTarget(event, GetApplicationEventTarget())
            ReleaseEvent(event)
            guard parameter == noErr, dispatched == noErr else { throw Failure.check }
            let before = callbacks
            try await Task.sleep(nanoseconds: 50_000_000)
            guard callbacks == before + 1 else { throw Failure.check }
            registrar.unregister()
            try conflict.register(shortcut); conflict.unregister()
        }
        try registrar.register(.disabled)
        guard registrar.activeShortcut == .disabled else { throw Failure.check }
        print("PASS: all three Carbon chords register, reject conflicts, dispatch only their hotkey event and release for reuse.")
    }
    enum Failure: Error { case check, collision }
}
