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
        print("PASS: template throughput label, bundled logo, actual SwiftUI close/reopen, Dock activation policy, unrelated-window ownership and synthetic session preservation; no VPN requests.")
    }
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "VPN Navigator" && !($0 is NSPanel) && $0.isVisible }
    }
    private static func settle() async throws { try await Task.sleep(nanoseconds: 350_000_000) }
    private enum Failure: Error { case check(String) }
}
