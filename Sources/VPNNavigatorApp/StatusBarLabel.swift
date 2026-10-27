import AppKit
import SwiftUI
import VPNNavigatorCore

@MainActor
enum AppBranding {
    static let icon: NSImage = load("AppIcon", "png") ?? NSImage(systemSymbolName: "location.north.circle.fill", accessibilityDescription: "VPN Navigator")!
    static let statusIcon: NSImage = load("StatusIcon", "pdf") ?? NSImage(systemSymbolName: "location.north.circle", accessibilityDescription: "VPN Navigator")!
    private static func load(_ name: String, _ ext: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Branding") else { return nil }
        return NSImage(contentsOf: url)
    }
    /// A single template image avoids MenuBarExtra dropping custom text or
    /// stack layouts on older macOS. Fixed bounds prevent the item from jumping.
    static func statusLabel(download: String, upload: String) -> NSImage {
        let symbol = statusIcon
        let image = NSImage(size: NSSize(width: 104, height: 22), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 1, y: 2, width: 18, height: 18))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: NSColor.black
            ]
            ("↓ " + download as NSString).draw(in: NSRect(x: 25, y: 11, width: 79, height: 11), withAttributes: attributes)
            ("↑ " + upload as NSString).draw(in: NSRect(x: 25, y: 0, width: 79, height: 11), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct StatusBarLabel: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let speed = model.connected ? model.menuTraffic.current() : nil
            let download = TunnelSpeedFormat.string(speed?.receivedPerSecond)
            let upload = TunnelSpeedFormat.string(speed?.sentPerSecond)
            let description = L10n.format("VPN Navigator，{0}。隧道下载 {1}，上传 {2}。", [model.menuStatusTitle, download, upload])
            Image(nsImage: AppBranding.statusLabel(download: download, upload: upload))
                .renderingMode(.template)
                .accessibilityLabel(description)
                .help(description)
        }
    }
}
