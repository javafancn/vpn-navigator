import AppKit
import VPNNavigatorCore

/// The real scene closes/reopens while a synthetic in-memory session remains
/// intact. Never connects to a helper, imports credentials or changes routes.
@MainActor
enum StatusBarSelfTest {
    private static var started = false
    static func begin() -> Bool {
        guard !started else { return false }
        started = true; return true
    }
    static func run(model: AppModel, openMainScene: () -> Void) async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check("CI only") }
        try await settle()
        let profile = VPNProfile(name: "Synthetic status fixture", sourceFilename: "fixture.ovpn", relativePath: "not-on-disk")
        let attempt = UUID()
        model.profiles = [profile]; model.selectedID = profile.id
        model.applyVerifiedSessionReport(.init(state: .connected, message: "synthetic, no VPN", activeProfileID: profile.id,
            receivedBytes: 1_000, sentBytes: 100, attemptID: attempt, networkRecoveryRequired: false, routingMode: .original))
        guard model.connected, !model.canQuit, model.menuTraffic.current() == nil else { throw Failure.check("session fixture") }
        let label = AppBranding.statusLabel(download: "999 MB/s", upload: "1.2 KB/s")
        guard label.isTemplate, label.size == NSSize(width: 84, height: 22),
              AppBranding.statusLabel(download: "999 MB/s", upload: "1.2 KB/s") === label,
              let bitmap = label.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), bitmap.pixelsWide >= 84 else { throw Failure.check("template label raster") }
        for rates in [("—", "—"), ("0 B/s", "0 B/s"), ("999 MB/s", "18.4 EB/s")] {
            let image = AppBranding.statusLabel(download: rates.0, upload: rates.1)
            guard let raster = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { throw Failure.check("throughput raster") }
            let scale = Double(raster.pixelsWide) / 84
            for half in [0, 1] {
                var ink = 0
                for y in Int(Double(half * 11 + 1) * scale)..<Int(Double(half * 11 + 10) * scale) {
                    for x in Int(34 * scale)..<Int(82 * scale) {
                        if (raster.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { ink += 1 }
                    }
                }
                guard ink > 3 else { throw Failure.check("rate value missing or clipped") }
            }
        }
        let idleLabel = AppBranding.statusLabel(download: "—", upload: "—", showsTraffic: false)
        guard idleLabel.size == NSSize(width: 22, height: 22), idleLabel.isTemplate else { throw Failure.check("idle status item keeps a standard icon width") }
        try await verifyMenuTracking(model: model, profile: profile, attempt: attempt)
        try await verifyMainMenuStability(model: model, profile: profile, attempt: attempt)
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon",
                  let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), NSImage(contentsOf: icon) != nil,
                  AppBranding.icon.representations.contains(where: { $0.pixelsWide == 1024 }),
                  Bundle.main.url(forResource: "StatusIcon", withExtension: "pdf", subdirectory: "Branding") != nil else { throw Failure.check("bundled branding") }
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 180, pixelsHigh: 180,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure.check("brand raster context") }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.clear(NSRect(x: 0, y: 0, width: 180, height: 180))
            AppBranding.statusIcon.draw(in: NSRect(x: 0, y: 0, width: 180, height: 180))
            NSGraphicsContext.restoreGraphicsState()
            for pixel in 0..<180 {
                for (x, y) in [(pixel, 0), (pixel, 179), (0, pixel), (179, pixel)] {
                    guard (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.01 else { throw Failure.check("status mark clipped or opaque at edge") }
                }
            }
            guard (bitmap.colorAt(x: 120, y: 70)?.alphaComponent ?? 0) > 0.5 else { throw Failure.check("status mark is empty") }
        }
        for _ in 0..<2 {
            model.quickAccess.openMainWindow()
            try await settle()
            guard NSApp.activationPolicy() == .regular, let window = mainWindow(), window.isVisible else { throw Failure.check("foreground and Dock restored") }
            window.miniaturize(nil); try await settle()
            guard NSApp.activationPolicy() == .regular else { throw Failure.check("minimize keeps Dock") }
            model.quickAccess.openMainWindow(); try await settle()
            guard !window.isMiniaturized, window.isVisible else { throw Failure.check("restore minimized main window") }
            // Closing an unrelated window must not hide the main window's Dock.
            let utility = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            utility.isReleasedWhenClosed = false; utility.close()
            try await settle()
            guard NSApp.activationPolicy() == .regular else { throw Failure.check("unrelated window ownership") }
            window.performClose(nil)
            try await settle()
            guard !window.isVisible, NSApp.activationPolicy() == .accessory,
                  model.connected, model.activeProfileID == profile.id, model.traffic?.receivedBytes == 1_000,
                  model.selectedID == profile.id, model.profiles.count == 1 else { throw Failure.check("background close preserves session") }
        }
        model.quickAccess.openMainWindow(); try await settle()
        guard NSApp.activationPolicy() == .regular, mainWindow()?.isVisible == true else { throw Failure.check("final scene reopen") }
        model.quickAccess.openMainWindow(); model.quickAccess.openMainWindow(); try await settle()
        guard NSApp.windows.filter({ $0.title == "VPN Navigator" && !($0 is NSPanel) && $0.isVisible }).count == 1 else { throw Failure.check("open reuses the single main workspace") }
        // Reopen in the same event turn must cancel a queued background switch.
        mainWindow()?.performClose(nil); model.quickAccess.openMainWindow(); model.quickAccess.openMainWindow(); try await settle()
        guard NSApp.activationPolicy() == .regular, mainWindow()?.isVisible == true,
              NSApp.windows.filter({ $0.title == "VPN Navigator" && !($0 is NSPanel) && $0.isVisible }).count == 1 else { throw Failure.check("close/reopen race") }
        // Exercise scene creation directly: the presentation coordinator alone
        // cannot prevent SwiftUI/AppKit from creating a second WindowGroup instance.
        let originalWindow = mainWindow()
        openMainScene(); openMainScene(); openMainScene()
        try await settle()
        try requireSingleMainWindow("concurrent scene opens", expected: originalWindow)

        let lifecycle = ApplicationLifecycle()
        lifecycle.model = model
        func dockReopen(hasVisibleWindows: Bool) throws {
            guard !lifecycle.applicationShouldHandleReopen(NSApp, hasVisibleWindows: hasVisibleWindows) else {
                throw Failure.check("Dock reopen must suppress default window creation")
            }
        }
        try dockReopen(hasVisibleWindows: true)
        try await settle()
        try requireSingleMainWindow("Dock reopen with visible workspace", expected: originalWindow)
        mainWindow()?.miniaturize(nil)
        try await settle()
        try dockReopen(hasVisibleWindows: false)
        try await settle()
        try requireSingleMainWindow("Dock restores minimized workspace", expected: originalWindow)
        mainWindow()?.orderOut(nil)
        try dockReopen(hasVisibleWindows: false)
        try await settle()
        try requireSingleMainWindow("Dock restores hidden workspace", expected: originalWindow)

        let utility = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        utility.isReleasedWhenClosed = false
        utility.orderFront(nil)
        defer { utility.close() }
        mainWindow()?.performClose(nil)
        try await settle()
        try dockReopen(hasVisibleWindows: true)
        try dockReopen(hasVisibleWindows: true)
        openMainScene()
        try await settle()
        try requireSingleMainWindow("Dock reopen while utility remains visible")
        mainWindow()?.performClose(nil)
        try dockReopen(hasVisibleWindows: false)
        try dockReopen(hasVisibleWindows: false)
        openMainScene()
        try await settle()
        try requireSingleMainWindow("Dock close/reopen race")
        guard model.connected, model.activeProfileID == profile.id else { throw Failure.check("Dock reopen preserves session") }
        print("PASS: stable foreground main menu and native status menu during polling, refreshed next-open state, template throughput label, bundled logo, single-instance SwiftUI scene, Dock reopen/minimize/hide/close races, unrelated-window ownership and synthetic session preservation; no VPN requests.")
    }
    private static func verifyMainMenuStability(model: AppModel, profile: VPNProfile, attempt: UUID) async throws {
        model.quickAccess.openMainWindow()
        try await settle()
        guard let root = NSApp.mainMenu, root.numberOfItems > 0 else { throw Failure.check("main menu readiness") }
        let items = root.items
        let titles = items.map(\.title)
        let submenus = items.map(\.submenu)
        // Check the actual AppKit objects after each traffic update with the
        // same foreground window. Presenting sheets legitimately changes the
        // responder/menu context on some systems and is tested separately by
        // WorkspaceAccessibilitySelfTest's modal command exclusion checks.
        for sample in 1...6 {
            model.applyVerifiedSessionReport(.init(state: .connected, message: "main menu polling fixture", activeProfileID: profile.id,
                receivedBytes: UInt64(sample) * 100_000, sentBytes: UInt64(sample) * 10_000,
                attemptID: attempt, networkRecoveryRequired: false, routingMode: .original))
            try await settle()
            guard NSApp.mainMenu === root, root.items.count == items.count,
                  root.items.map(\.title) == titles,
                  zip(root.items, items).allSatisfy({ $0 === $1 }),
                  zip(root.items.map(\.submenu), submenus).allSatisfy({ $0 === $1 }) else {
                throw Failure.check("traffic rebuilt the foreground main menu at sample \(sample)")
            }
        }
        model.applyVerifiedSessionReport(.init(state: .connected, message: "synthetic, no VPN", activeProfileID: profile.id,
            receivedBytes: 1_000, sentBytes: 100, attemptID: attempt, networkRecoveryRequired: false, routingMode: .original))
        try await settle()
    }
    private static func verifyMenuTracking(model: AppModel, profile: VPNProfile, attempt: UUID) async throws {
        let controller = StatusBarMenuController(model: model, installsStatusItem: false)
        defer { controller.shutdown() }
        let menu = controller.menu
        controller.menuNeedsUpdate(menu)
        let originalItems = menu.items
        let originalTitles = originalItems.map(\.title)
        guard let routing = menu.item(withTitle: L10n.text("路由模式"))?.submenu,
              let smart = menu.item(withTitle: L10n.text("智能连接"))?.submenu else { throw Failure.check("native submenus") }
        let routingItems = routing.items, smartItems = smart.items
        let openMain = model.quickAccess.openMainWindow
        var opens = 0
        model.quickAccess.openMainWindow = { opens += 1 }
        defer {
            model.quickAccess.openMainWindow = openMain
            model.applyVerifiedSessionReport(.init(state: .connected, message: "synthetic, no VPN", activeProfileID: profile.id,
                receivedBytes: 1_000, sentBytes: 100, attemptID: attempt, networkRecoveryRequired: false, routingMode: .original))
        }
        controller.menuWillOpen(menu)
        for sample in 1...3 {
            model.applyVerifiedSessionReport(.init(state: .connected, message: "synthetic polling", activeProfileID: profile.id,
                receivedBytes: UInt64(sample + 1) * 1_000, sentBytes: UInt64(sample + 1) * 100,
                attemptID: attempt, networkRecoveryRequired: false, routingMode: .original))
            try await Task.sleep(nanoseconds: 1_050_000_000)
            controller.menuNeedsUpdate(menu)
            guard menu.items.count == originalItems.count, menu.items.map(\.title) == originalTitles,
                  zip(menu.items, originalItems).allSatisfy({ $0 === $1 }),
                  routing.items.count == routingItems.count, smart.items.count == smartItems.count,
                  zip(routing.items, routingItems).allSatisfy({ $0 === $1 }),
                  zip(smart.items, smartItems).allSatisfy({ $0 === $1 }),
                  menu.item(withTitle: L10n.text("路由模式"))?.submenu === routing else {
                throw Failure.check("polling replaced an open native menu or submenu")
            }
        }
        guard let openItem = menu.item(withTitle: L10n.text("打开主窗口")) else { throw Failure.check("native window command") }
        menu.performActionForItem(at: menu.index(of: openItem))
        guard opens == 1 else { throw Failure.check("menu command survived polling") }
        // A disconnect while the menu is open must not turn its stale
        // disconnect command into a new connection attempt.
        model.applyVerifiedSessionReport(.init(state: .disconnected, message: "synthetic disconnect", activeProfileID: nil,
            receivedBytes: nil, sentBytes: nil, networkRecoveryRequired: false))
        guard let connection = menu.item(withTitle: L10n.text("VPN 连接")), connection.state == .on else {
            throw Failure.check("tracking snapshot remains stable")
        }
        menu.performActionForItem(at: menu.index(of: connection))
        try await settle()
        guard !model.connected, !model.connecting, !model.busy else { throw Failure.check("stale toggle started a connection") }
        controller.menuDidClose(menu)
        controller.menuNeedsUpdate(menu)
        guard menu.item(withTitle: L10n.text("VPN 连接"))?.state == .off,
              menu.item(withTitle: L10n.text("路由模式"))?.submenu !== routing else {
            throw Failure.check("next menu opening refreshes the session snapshot")
        }
        // Enter AppKit's actual event-tracking loop. Polling and native menu
        // validation during that loop must preserve the same submenu objects.
        guard let view = mainWindow()?.contentView else { throw Failure.check("menu tracking host") }
        let probe = MenuTrackingProbe(menu: menu, model: model, profile: profile, attempt: attempt)
        let timer = Timer(timeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { probe.poll() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        menu.popUp(positioning: nil, at: NSPoint(x: 24, y: 100), in: view)
        guard probe.ticks >= 4, probe.stable, probe.submenu != nil else { throw Failure.check("actual AppKit menu tracking survived polling") }
    }
    @MainActor
    private final class MenuTrackingProbe {
        let menu: NSMenu
        let model: AppModel
        let profile: VPNProfile
        let attempt: UUID
        var ticks = 0, stable = true
        var items: [NSMenuItem] = []
        var submenu: NSMenu?
        init(menu: NSMenu, model: AppModel, profile: VPNProfile, attempt: UUID) {
            self.menu = menu; self.model = model; self.profile = profile; self.attempt = attempt
        }
        func poll() {
            if ticks == 0 {
                items = menu.items
                submenu = menu.item(withTitle: L10n.text("路由模式"))?.submenu
            }
            ticks += 1
            model.applyVerifiedSessionReport(.init(state: .connected, message: "tracking loop fixture", activeProfileID: profile.id,
                receivedBytes: UInt64(ticks) * 1_000, sentBytes: UInt64(ticks) * 100,
                attemptID: attempt, networkRecoveryRequired: false, routingMode: .original))
            menu.update()
            stable = stable && menu.items.count == items.count && zip(menu.items, items).allSatisfy({ $0 === $1 }) &&
                menu.item(withTitle: L10n.text("路由模式"))?.submenu === submenu
            if ticks >= 4 { menu.cancelTracking() }
        }
    }
    private static func requireSingleMainWindow(_ check: String, expected: NSWindow? = nil) throws {
        let windows = NSApp.windows.filter { $0.title == "VPN Navigator" && !($0 is NSPanel) && ($0.isVisible || $0.isMiniaturized) }
        guard windows.count == 1, let window = windows.first, window.isVisible, !window.isMiniaturized,
              expected == nil || window === expected, NSApp.activationPolicy() == .regular else { throw Failure.check(check) }
    }
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "VPN Navigator" && !($0 is NSPanel) && $0.isVisible }
    }
    private static func settle() async throws { try await Task.sleep(nanoseconds: 350_000_000) }
    private enum Failure: Error { case check(String) }
}
