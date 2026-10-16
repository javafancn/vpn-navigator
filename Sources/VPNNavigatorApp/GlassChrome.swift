import SwiftUI
import AppKit

/// Reference palette covers controls only. Desktop scenery is NEVER painted
/// by VPN Navigator; only the user's macOS wallpaper shows through.
enum GlassPalette {
    static let blue = Color(red: 0.05, green: 0.45, blue: 0.98)
    static let cyan = Color(red: 0.10, green: 0.73, blue: 1.0)
    static let ink = Color(red: 0.08, green: 0.14, blue: 0.27)
    static let violet = Color(red: 0.67, green: 0.60, blue: 0.94)
}

/// This is the actual macOS desktop backdrop, not an app-drawn landscape.
/// The wallpaper belongs to the OS and changes as the user changes desktops.
/// Avoid gradients, mountain artwork and any opaque full-window fill.
struct GlassAtmosphere: View {
    var body: some View {
        DesktopVisualEffect()
            .ignoresSafeArea()
            .accessibilityHidden(true)
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
        // Let users drag the chrome, not form controls or cards.
        window.isMovableByWindowBackground = true
    }
}

struct DesktopVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeWindowGlass {
        let view = NativeWindowGlass()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        // A fully opaque under-window material hides colorful wallpapers.
        // Compose only a fraction of the native blur over a CLEAR NSWindow.
        view.alphaValue = 0.32
        return view
    }
    func updateNSView(_ view: NativeWindowGlass, context: Context) {
        view.configureWindow()
        view.alphaValue = 0.32
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
                // The window's behind-window NSVisualEffectView has already
                // blurred the wallpaper. An additional SwiftUI material here
                // resolves to a solid gray on macOS 15 and masks the desktop.
                // Translucent color gives a genuine frosted-glass surface
                // while allowing the OS-provided wallpaper to show through.
                shape
                    .fill(opaqueFallback
                          ? Color(nsColor: .windowBackgroundColor)
                          : (appearance == .dark
                             ? Color.black.opacity(0.28)
                             : Color.white.opacity(0.32)))
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [
                        Color.white.opacity(appearance == .dark ? 0.40 : 0.92),
                        Color.white.opacity(0.25)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            }
            .shadow(color: GlassPalette.ink.opacity(active ? 0.15 : 0.08),
                    radius: active ? 16 : 10, y: active ? 6 : 3)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16,
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
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.27)
                            .fill(color.opacity(0.10))
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
                .font(.system(size: 9))
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
                .font(.system(size: size * 0.60, weight: .semibold))
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
        .shadow(color: GlassPalette.blue.opacity(0.12), radius: 6, y: 3)
        .accessibilityLabel("VPN Navigator")
    }
}
