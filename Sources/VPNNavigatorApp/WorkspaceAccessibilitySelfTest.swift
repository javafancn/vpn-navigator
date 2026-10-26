import AppKit
import VPNNavigatorCore

/// Exercises the real SwiftUI scene, generated native menus, AppKit responder
/// chain and in-process accessibility tree. No external accessibility grant,
/// VPN, file import, credential storage or public network request is involved.
@MainActor
enum WorkspaceAccessibilitySelfTest {
    static func run(model: AppModel, navigation: WorkspaceNavigation, router: WorkspaceCommandRouter) async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check("CI only") }
        let a = VPNProfile(name: "Alpha", sourceFilename: "alpha.ovpn", relativePath: "fixture-only", isFavorite: true)
        let b = VPNProfile(name: "Beta", sourceFilename: "beta.ovpn", relativePath: "fixture-only")
        model.profiles = [a, b]; model.selectedID = nil
        NSApp.activate(ignoringOtherApps: true)
        try await settle()
        guard let window = NSApp.windows.first(where: { $0.title == "VPN Navigator" && !($0 is NSPanel) }) else { throw Failure.check("main window") }
        NSApp.setActivationPolicy(.regular)
        window.makeMain(); window.makeKeyAndOrderFront(nil)
        for _ in 0..<15 {
            if NSApp.isActive && window.isKeyWindow && window.isMainWindow { break }
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try await settle()
        guard NSApp.isActive, window.isKeyWindow, window.isMainWindow else { throw Failure.check("active main scene") }
        func element(_ identifier: String) throws -> NSAccessibilityProtocol {
            var visited = Set<ObjectIdentifier>()
            func find(_ item: Any, depth: Int) -> NSAccessibilityProtocol? {
                guard depth < 40, visited.count < 6000 else { return nil }
                let object = item as AnyObject
                guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
                if let node = item as? NSAccessibilityProtocol {
                    if node.accessibilityIdentifier() == identifier { return node }
                    for child in node.accessibilityChildren() ?? [] { if let match = find(child, depth: depth + 1) { return match } }
                }
                if let view = item as? NSView {
                    for child in view.subviews { if let match = find(child, depth: depth + 1) { return match } }
                }
                return nil
            }
            if let result = find(window, depth: 0) { return result }
            throw Failure.check("missing accessibility element: " + identifier)
        }
        func event(_ code: UInt16, text: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            guard let result = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { throw Failure.check("key event") }
            return result
        }
        func command(_ text: String, code: UInt16) throws {
            // Use AppKit's normal event dispatcher. Manually calling update()
            // on SwiftUI-owned NSMenus invokes a different validation path.
            NSApp.sendEvent(try event(code, text: text, modifiers: .command))
        }
        print("Workspace router readiness:", router.selfTestState(), "nativeDialog=", model.nativeDialogPresented,
              "message=", model.message != nil, "setup=", model.showingSetup, "maintenance=", model.showingMaintenance)
        if let menu = NSApp.mainMenu?.items.first(where: { $0.title == "工作区" })?.submenu {
            print("Workspace command readiness:", menu.items.filter { !$0.isSeparatorItem }.map { "\($0.title):\($0.keyEquivalent):\($0.isEnabled)" })
        }
        try command("2", code: 19); try await settle()
        guard navigation.tab == .profiles else { throw Failure.check("command-2 navigation") }
        let profiles = try element("workspace-profiles")
        guard profiles.accessibilityLabel() == "配置文件", String(describing: profiles.accessibilityValue()).contains("已选择") else { throw Failure.check("workspace semantics") }
        try command("f", code: 3); try await settle()
        let firstSearch = navigation.searchRequest
        guard window.firstResponder is NSTextView, firstSearch != nil else { throw Failure.check("search focus") }
        try command("f", code: 3); try await settle()
        guard navigation.searchRequest != firstSearch, window.firstResponder is NSTextView else { throw Failure.check("repeated search") }
        _ = try element("profile-library-search")
        // Return selects a result and moves keyboard focus; arrows are handled
        // only by rows, leaving text editing and marked-text handling native.
        window.sendEvent(try event(36, text: "\r")); try await settle()
        guard model.selectedID == a.id, !(window.firstResponder is NSTextView) else { throw Failure.check("search to list focus") }
        window.sendEvent(try event(125, text: "\u{f701}")); try await settle()
        guard model.selectedID == b.id else { throw Failure.check("list down") }
        window.sendEvent(try event(125, text: "\u{f701}")); try await settle()
        guard model.selectedID == b.id else { throw Failure.check("list boundary") }
        window.sendEvent(try event(126, text: "\u{f700}")); try await settle()
        guard model.selectedID == a.id else { throw Failure.check("list up") }
        let row = try element("library-profile-" + a.id.uuidString)
        guard row.accessibilityLabel() == "Alpha", String(describing: row.accessibilityValue()).contains("已收藏") else { throw Failure.check("profile semantics") }
        model.connectionStatus = "connected: fixture only"; model.activeProfileID = a.id
        try await settle()
        let other = try element("library-profile-" + b.id.uuidString)
        guard other.accessibilityPerformPress() else { throw Failure.check("accessible selection action") }
        try await settle()
        guard model.selectedID == b.id, model.connected, model.activeProfileID == a.id else { throw Failure.check("selection must not connect") }
        try command("1", code: 18); try await settle()
        guard navigation.tab == .overview, try element("vpn-power").accessibilityLabel() == "断开 VPN" else { throw Failure.check("power semantics") }
        try command("f", code: 3); try await settle()
        guard navigation.tab == .profiles, window.firstResponder is NSTextView else { throw Failure.check("cross-workspace search focus") }
        model.profileLibrary.query = "no result"; try await settle()
        window.sendEvent(try event(36, text: "\r")); try await settle()
        guard model.selectedID == b.id, window.firstResponder is NSTextView else { throw Failure.check("empty search keeps selection and text focus") }
        model.profileLibrary.clearFilters()
        // Also cover locally owned editor/delete sheets that have no flag in
        // AppModel. Native sheet ownership must block background navigation.
        let localSheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        localSheet.isReleasedWhenClosed = false
        window.beginSheet(localSheet, completionHandler: nil); try await settle()
        guard model.nativeDialogPresented, !model.canChooseProfileFiles, model.workspaceNavigationBlocked, model.smartConnectionContext().occupied else { throw Failure.check("native sheet exclusion") }
        try command("1", code: 18)
        try await settle()
        guard navigation.tab == .profiles else { throw Failure.check("native sheet navigated background") }
        window.endSheet(localSheet); localSheet.orderOut(nil); try await settle()
        guard !model.nativeDialogPresented else { throw Failure.check("native sheet dismissal") }
        try command("1", code: 18); try await settle()
        guard navigation.tab == .overview else { throw Failure.check("commands resume after native sheet") }
        let otherWindow = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false; otherWindow.makeKeyAndOrderFront(nil); try await settle()
        guard otherWindow.isKeyWindow, !router.available else { throw Failure.check("foreign window disables workspace commands") }
        router.select(.settings)
        guard navigation.tab == .overview else { throw Failure.check("foreign window routed into main") }
        otherWindow.orderOut(nil); window.makeMain(); window.makeKeyAndOrderFront(nil); try await settle()
        guard router.available else { throw Failure.check("main window commands resume") }
        model.showingKeyboardHelp = true; try await settle()
        guard model.workspaceNavigationBlocked, model.smartConnectionContext().occupied,
              model.quickAccessAction(for: b.id) == .blocked else { throw Failure.check("help modal exclusion") }
        model.showingKeyboardHelp = false; try await settle()
        model.connectionStatus = "disconnected: fixture"; model.activeProfileID = nil
        guard !model.workspaceNavigationBlocked else { throw Failure.check("commands resume after dismissal") }
        model.showingAccountCredentials = true
        guard model.workspaceNavigationBlocked else { throw Failure.check("authentication modal exclusion") }
        model.showingAccountCredentials = false
        print("PASS workspace accessibility: actual native command-1/2/F, repeated/cross-page search focus, Return and list arrows/bounds, empty results, accessible profile press without VPN change, selected/favorite/power labels and native/model modal exclusion; no network requests")
    }
    private static func settle() async throws { try await Task.sleep(nanoseconds: 400_000_000) }
    enum Failure: Error { case check(String) }
}
