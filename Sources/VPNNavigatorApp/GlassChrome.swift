import SwiftUI
import AppKit

/// Reference palette covers controls only. Desktop scenery is NEVER painted
/// by VPN Navigator; only the user's macOS wallpaper shows through.
enum GlassPalette {
    static let blue = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let cyan = Color(red: 0.10, green: 0.73, blue: 1.0)
    static let ink = Color(red: 0.055, green: 0.075, blue: 0.18)
    static let violet = Color(red: 0.67, green: 0.60, blue: 0.94)
}

/// Shared visual measurements for all five workspaces. Keep these independent
/// of VPN session and route state so a fidelity pass cannot alter networking.
enum GlassLayout {
    static let pageInset: CGFloat = 20
    static let pageTop: CGFloat = 30
    static let cardGap: CGFloat = 12
    static let cornerRadius: CGFloat = 18
    static let sectionSpacing: CGFloat = 13
}


// Screenshot-only material calibration. Each preset renders the *real* desktop
// using native AppKit; no wallpaper or screenshot is bundled with the app.
// Standard users get the tuned default, not a demonstration background.
private enum GlassMaterialTuning {
    static let preset: String = ProcessInfo.processInfo.arguments
        .first(where: { $0.hasPrefix("--vpnnav-glass-preset=") })?
        .split(separator: "=", maxSplits: 1).last.map(String.init) ?? "standard"

    static var windowMaterial: NSVisualEffectView.Material {
        switch preset {
        case "popover": return .popover
        case "sidebar": return .sidebar
        case "hud": return .hudWindow
        default: return .sidebar
        }
    }
    static var cardMaterial: NSVisualEffectView.Material {
        switch preset {
        case "popover": return .popover
        case "sidebar": return .sidebar
        case "hud": return .hudWindow
        default: return .sidebar
        }
    }
    static var windowAlpha: CGFloat {
        switch preset {
        case "strong": return 1.0
        case "popover", "sidebar", "hud": return 0.84
        default: return 0.82
        }
    }
    static var cardAlpha: CGFloat {
        switch preset {
        case "strong": return 1.0
        case "popover", "sidebar", "hud": return 0.84
        default: return 0.25
        }
    }
}


/// Light glass colors are intentionally near-neutral instead of a saturated
/// blue overlay: the supplied design is a white-lilac frost, not clear glass.
enum GlassSurface {
    static let mist = Color(red: 0.91, green: 0.95, blue: 1.00)
    static let sidebar = Color(red: 0.76, green: 0.84, blue: 0.96)
    static let panel = Color(red: 0.97, green: 0.985, blue: 1.00)

    /// For screenshot calibration against the reference, without modifying
    /// the Mac's wallpaper or embedding a background image.
    static let preset: String = ProcessInfo.processInfo.arguments
        .first(where: { $0.hasPrefix("--vpnnav-mist=") })?
        .split(separator: "=", maxSplits: 1).last.map(String.init) ?? "reference"

    static var windowOpacity: Double {
        switch preset {
        case "lighter": return 0.46
        case "denser": return 0.79
        default: return 0.25
        }
    }
    static var cardOpacity: Double {
        switch preset {
        case "lighter": return 0.62
        case "denser": return 0.91
        default: return 0.32
        }
    }
}

/// This is the actual macOS desktop backdrop, not an app-drawn landscape.
/// The wallpaper belongs to the OS and changes as the user changes desktops.
/// Avoid gradients, mountain artwork and any opaque full-window fill.
struct GlassAtmosphere: View {
    @Environment(\.colorScheme) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            DesktopVisualEffect()
            // Native blur softens wallpaper detail; this independent veil
            // reduces wallpaper contrast. Blur alpha alone cannot do both.
            if reduceTransparency &&
                !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-glass-snapshot") {
                Color(nsColor: .windowBackgroundColor)
            } else {
                GlassSurface.mist.opacity(
                    appearance == .dark ? GlassSurface.windowOpacity * 0.55 :
                                          GlassSurface.windowOpacity)
                // Gentle blue-lilac atmospheric light, like the design
                // reference, over REAL macOS vibrancy. Not a wallpaper.
                LinearGradient(
                    colors: [
                        GlassPalette.blue.opacity(appearance == .dark ? 0.025 : 0.055),
                        Color.clear,
                        GlassPalette.violet.opacity(appearance == .dark ? 0.025 : 0.025)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(
                    colors: [GlassPalette.cyan.opacity(appearance == .dark ? 0.018 : 0.045),
                             .clear],
                    center: .topTrailing, startRadius: 22, endRadius: 620)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

final class NativeWindowGlass: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }
    func configureWindow() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // Keep the same 11:7 proportion on every tab and during resizing.
        if window.title.contains("VPN Navigator"), !(window is NSPanel) {
            window.contentAspectRatio = NSSize(width: 11, height: 7)
        }
        // Let users drag the chrome, not form controls or cards.
        window.isMovableByWindowBackground = true

    }
}

struct DesktopVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeWindowGlass {
        let view = NativeWindowGlass()
        view.material = GlassMaterialTuning.windowMaterial
        view.blendingMode = .behindWindow
        view.state = .active
        // A fully opaque under-window material hides colorful wallpapers.
        // Compose only a fraction of the native blur over a CLEAR NSWindow.
        view.alphaValue = GlassMaterialTuning.windowAlpha
        return view
    }
    func updateNSView(_ view: NativeWindowGlass, context: Context) {
        view.configureWindow()
        view.material = GlassMaterialTuning.windowMaterial
        view.alphaValue = GlassMaterialTuning.windowAlpha
    }
}

/// Per-card AppKit blur samples the same desktop as the transparent window.
/// Unlike nesting opaque SwiftUI materials, a fractional native visual effect
/// adds local diffusion without hiding the wallpaper with a solid gray surface.
private struct NativeCardBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = GlassMaterialTuning.cardMaterial
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = GlassMaterialTuning.cardAlpha
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = GlassMaterialTuning.cardMaterial
        view.alphaValue = GlassMaterialTuning.cardAlpha
    }
}

/// Broad rounded workspace behind the actual cards. The reference uses a
/// translucent content canvas in addition to the individual frosted tiles;
/// without this layer the header looks detached from the whole page.
struct ReferenceWorkspaceSurface: ViewModifier {
    @Environment(\.colorScheme) private var appearance
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .background {
                shape.fill(appearance == .dark ?
                    Color.white.opacity(0.055) :
                    Color(red: 0.90, green: 0.95, blue: 1).opacity(0.12))
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [
                        Color.white.opacity(0.84),
                        Color.white.opacity(0.14),
                        Color.white.opacity(0.32)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            }
    }
}
extension View {
    func referenceWorkspaceSurface() -> some View {
        modifier(ReferenceWorkspaceSurface())
    }
}

/// Layered native glass: keep the wallpaper visible in the clear NSWindow
/// while giving text and controls their own *local* blur and readable tint.
/// No wallpaper image, opaque app background, or fake macOS glass API.
private struct GlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat
    var active: Bool

    func body(content: Content) -> some View {
        // CI runners may force Reduce Transparency in their accessibility
        // configuration. An explicit UI-only snapshot flag lets screenshots
        // exercise normal glass without changing the user's system setting.
        let opaqueFallback = reduceTransparency &&
            !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-glass-snapshot")
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if opaqueFallback {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(appearance == .dark
                               ? Color.black.opacity(0.22)
                               : GlassSurface.panel.opacity(GlassSurface.cardOpacity))
                    // A subtle upper-left highlight separates layered panes
                    // without painting an opaque card over the desktop.
                    shape.fill(LinearGradient(colors: [
                        Color.white.opacity(appearance == .dark ? 0.07 : 0.24),
                        Color.white.opacity(appearance == .dark ? 0.01 : 0.08),
                        GlassPalette.violet.opacity(appearance == .dark ? 0.025 : 0.025)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if active {
                        shape.fill(RadialGradient(colors: [
                            GlassPalette.cyan.opacity(0.11), .clear
                        ], center: .topLeading, startRadius: 0, endRadius: 350))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [
                        Color.white.opacity(appearance == .dark ? 0.38 : 0.93),
                        GlassPalette.blue.opacity(appearance == .dark ? 0.08 : 0.09),
                        Color.white.opacity(0.34)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            }
            .shadow(color: GlassPalette.ink.opacity(0.025), radius: 5, y: 2)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18,
                   active: Bool = false) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, active: active))
    }
}

struct GlassIcon: View {
    var symbol: String
    var color: Color = GlassPalette.blue
    var size: CGFloat = 38
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.27)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.95),
                                                  Color(red: 0.82, green: 0.91, blue: 1).opacity(0.70)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.27)
                            .fill(color.opacity(0.08))
                    }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.27)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
    }
}

struct TrafficSparkline: View {
    let samples: [Double]
    var color: Color = GlassPalette.blue

    var body: some View {
        if samples.count >= 3 {
            GeometryReader { proxy in
                let high = max(samples.max() ?? 1, 1)
                Path { path in
                    for (i, sample) in samples.enumerated() {
                        let x = proxy.size.width * CGFloat(i) /
                                CGFloat(max(1, samples.count - 1))
                        let y = proxy.size.height *
                                (0.88 - 0.76 * CGFloat(sample / high))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6,
                                                 lineCap: .round, lineJoin: .round))
            }
            .accessibilityLabel("真实 OpenVPN 流量趋势")
        } else {
            Text("连接后显示趋势")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .leading)
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [
                    Color.white.opacity(0.98), Color(red: 0.80, green: 0.90, blue: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "globe")
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(GlassPalette.blue)
                .shadow(color: GlassPalette.cyan.opacity(0.25), radius: 2)
            Image(systemName: "shield.fill")
                .font(.system(size: size * 0.25, weight: .semibold))
                .foregroundStyle(GlassPalette.blue)
                .padding(2)
                .background(Color.white, in: Circle())
                .offset(x: size * 0.24, y: size * 0.22)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.27)
            .strokeBorder(Color.white.opacity(0.92), lineWidth: 1))
        .shadow(color: GlassPalette.blue.opacity(0.16), radius: 9, y: 3)
        .accessibilityLabel("VPN Navigator")
    }
}

