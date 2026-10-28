import AppKit
import Combine
import SwiftUI
import VPNNavigatorCore

@MainActor
enum AppBranding {
    static let icon: NSImage = load("AppIcon", "png") ?? NSImage(systemSymbolName: "location.north.circle.fill", accessibilityDescription: "VPN Navigator")!
    static let statusIcon: NSImage = load("StatusIcon", "pdf") ?? NSImage(systemSymbolName: "location.north.circle", accessibilityDescription: "VPN Navigator")!
    private static var cachedStatus: (download: String, upload: String, image: NSImage)?
    private static func load(_ name: String, _ ext: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Branding") else { return nil }
        return NSImage(contentsOf: url)
    }
    /// A single template image avoids MenuBarExtra dropping custom text or
    /// stack layouts on older macOS. Fixed bounds prevent the item from jumping.
    static func statusLabel(download: String, upload: String) -> NSImage {
        if let cachedStatus, cachedStatus.download == download, cachedStatus.upload == upload { return cachedStatus.image }
        let symbol = statusIcon
        let image = NSImage(size: NSSize(width: 84, height: 22), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 2, y: 3, width: 16, height: 16), from: .zero,
                        operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.black
            ]
            // Point drawing avoids NSString's line-fragment clipping inside
            // a rectangle shorter than the font's actual line height.
            ("↓ " + download.replacingOccurrences(of: " ", with: "") as NSString)
                .draw(at: NSPoint(x: 22, y: 10.5), withAttributes: attributes)
            ("↑ " + upload.replacingOccurrences(of: " ", with: "") as NSString)
                .draw(at: NSPoint(x: 22, y: 0), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        cachedStatus = (download, upload, image)
        return image
    }
}

struct StatusBarLabel: View {
    @EnvironmentObject private var model: AppModel
    @State private var tick = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        // TimelineView's dynamic schedule in a MenuBarExtra label can keep
        // SwiftUI's native status-item image extraction from settling at launch.
        // A stable image identity and an ordinary timer avoid that update loop.
        let _ = tick
            let speed = model.connected ? model.menuTraffic.current() : nil
            let download = TunnelSpeedFormat.string(speed?.receivedPerSecond)
            let upload = TunnelSpeedFormat.string(speed?.sentPerSecond)
            let description = L10n.format("VPN Navigator，{0}。隧道下载 {1}，上传 {2}。", [model.menuStatusTitle, download, upload])
            Image(nsImage: AppBranding.statusLabel(download: download, upload: upload))
                .renderingMode(.template)
                .frame(width: 84, height: 22)
                .accessibilityLabel(description)
                .help(description)
                .onReceive(clock) { tick = $0 }
    }
}
