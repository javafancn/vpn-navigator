import AppKit

@MainActor
enum AppBranding {
    static let icon: NSImage = load("AppIcon", "png") ?? NSImage(systemSymbolName: "location.north.circle.fill", accessibilityDescription: "VPN Navigator")!
    static let statusIcon: NSImage = load("StatusIcon", "pdf") ?? NSImage(systemSymbolName: "location.north.circle", accessibilityDescription: "VPN Navigator")!
    private static var cachedStatus: (download: String, upload: String, showsTraffic: Bool, image: NSImage)?
    private static func load(_ name: String, _ ext: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Branding") else { return nil }
        return NSImage(contentsOf: url)
    }
    /// A single template image keeps the icon and rates aligned on all supported
    /// macOS versions. Fixed bounds prevent the item from jumping.
    static func statusLabel(download: String, upload: String, showsTraffic: Bool = true) -> NSImage {
        if let cachedStatus, cachedStatus.download == download, cachedStatus.upload == upload,
           cachedStatus.showsTraffic == showsTraffic { return cachedStatus.image }
        let symbol = statusIcon
        let image = NSImage(size: NSSize(width: showsTraffic ? 84 : 22, height: 22), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 2, y: 3, width: 16, height: 16), from: .zero,
                        operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            guard showsTraffic else { return true }
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
        cachedStatus = (download, upload, showsTraffic, image)
        return image
    }
}
