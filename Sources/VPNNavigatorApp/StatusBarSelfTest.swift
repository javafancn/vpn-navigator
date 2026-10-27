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
    static func run(model: AppModel) async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check("CI only") }
        try await settle()
        let profile = VPNProfile(name: "Synthetic status fixture", sourceFilename: "fixture.ovpn", relativePath: "not-on-disk")
        let attempt = UUID()
        model.profiles = [profile]; model.selectedID = profile.id
        model.applyVerifiedSessionReport(.init(state: .connected, message: "synthetic, no VPN", activeProfileID: profile.id,
            receivedBytes: 1_000, sentBytes: 100, attemptID: attempt, networkRecoveryRequired: false, routingMode: .original))
        guard model.connected, !model.canQuit, model.menuTraffic.current() == nil else { throw Failure.check("session fixture") }
        let label = AppBranding.statusLabel(download: "999 MB/s", upload: "1.2 KB/s")
        guard label.isTemplate, label.size == NSSize(width: 104, height: 22),
              let bitmap = label.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), bitmap.pixelsWide >= 104 else { throw Failure.check("template label raster") }
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon",
                  let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), NSImage(contentsOf: icon) != nil,
                  AppBranding.icon.representations.contains(where: { $0.pixelsWide == 1024 }),
                  Bundle.main.url(forResource: "StatusIcon", withExtension: "pdf", subdirectory: "Branding") != nil else { throw Failure.check("bundled branding") }
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
        // Reopen in the same event turn must cancel a queued background switch.
        mainWindow()?.performClose(nil); model.quickAccess.openMainWindow(); try await settle()
        guard NSApp.activationPolicy() == .regular, mainWindow()?.isVisible == true else { throw Failure.check("close/reopen race") }
        print("PASS: template throughput label, bundled logo, actual SwiftUI close/reopen, Dock activation policy, unrelated-window ownership and synthetic session preservation; no VPN requests.")
    }
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "VPN Navigator" && !($0 is NSPanel) && $0.isVisible }
    }
    private static func settle() async throws { try await Task.sleep(nanoseconds: 350_000_000) }
    private enum Failure: Error { case check(String) }
}
