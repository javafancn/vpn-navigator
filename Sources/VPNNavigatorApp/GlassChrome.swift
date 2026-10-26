import VPNNavigatorCore
import SwiftUI
import AppKit

/// Reference palette covers controls only. Desktop scenery is NEVER painted
/// by VPN Navigator; only the user's macOS wallpaper shows through.
enum GlassPalette {
    static let blue = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let cyan = Color(red: 0.10, green: 0.73, blue: 1.0)
    static let ink = Color(red: 0.055, green: 0.075, blue: 0.18)
}

/// Shared visual measurements for all five workspaces. Keep these independent
/// of VPN session and route state so a fidelity pass cannot alter networking.
enum GlassLayout {
    static let pageInset: CGFloat = 24
    static let pageTop: CGFloat = 24
    static let cardGap: CGFloat = 12
    static let cornerRadius: CGFloat = 18
    static let sectionSpacing: CGFloat = 13
}


/// Neutral optical layers. Wallpaper colour belongs to WindowServer, not to
/// application gradients. Keep these shared fills achromatic on every page.
/// A CI-only composition fixture, without mutating the read-only system
/// contrast environment or changing the user's accessibility preferences.
enum GlassAccessibility {
    static func increasedContrast(_ system: ColorSchemeContrast) -> Bool {
        system == .increased || (ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" &&
            ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-high-contrast-snapshot"))
    }
}

enum GlassSurface {
    static let mist = Color.white
    static let sidebar = Color.white
    static let panel = Color.white
    static let windowOpacity = 0.045
    static let cardOpacity = 0.16
}

struct GlassAtmosphere: View {
    var onWindow: ((NSWindow) -> Void)? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            DesktopVisualEffect(onWindow: onWindow)
            if GlassAccessibility.increasedContrast(contrast) || (reduceTransparency &&
                !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-glass-snapshot")) {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Color.white.opacity(GlassSurface.windowOpacity)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

final class NativeWindowGlass: NSVisualEffectView {
    var onWindow: ((NSWindow) -> Void)?
    private weak var configuredWindow: NSWindow?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }
    func configureWindow() {
        guard let window else { return }
        onWindow?(window)
        if configuredWindow !== window {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            configuredWindow = window
        }
        // Do not reset window chrome/geometry on every model or typing update.
        let aspect = NSSize(width: 11, height: 7)
        if window.title.contains("VPN Navigator"), !(window is NSPanel),
           window.contentAspectRatio != aspect {
            window.contentAspectRatio = aspect
        }
    }
}

/// One full-strength native blur. Lowering the effect view's alpha also
/// reveals unblurred wallpaper; tune readability with the neutral veil above.
struct DesktopVisualEffect: NSViewRepresentable {
    var onWindow: ((NSWindow) -> Void)? = nil
    func makeNSView(context: Context) -> NativeWindowGlass {
        let view = NativeWindowGlass()
        view.onWindow = onWindow
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NativeWindowGlass, context: Context) {
        view.onWindow = onWindow
        view.configureWindow()
    }
}

/// Broad rounded workspace behind the actual cards. The reference uses a
/// translucent content canvas in addition to the individual frosted tiles;
/// without this layer the header looks detached from the whole page.
struct ReferenceWorkspaceSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .background(shape.fill(Color.white.opacity(0.035)))
            .overlay(shape.strokeBorder(GlassAccessibility.increasedContrast(contrast) ? Color.primary.opacity(0.55) : Color.white.opacity(0.30), lineWidth: GlassAccessibility.increasedContrast(contrast) ? 1.5 : 0.75)
                .allowsHitTesting(false))
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var cornerRadius: CGFloat
    var active: Bool

    func body(content: Content) -> some View {
        let opaqueFallback = GlassAccessibility.increasedContrast(contrast) || (reduceTransparency &&
            !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-glass-snapshot"))
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(opaqueFallback ? Color(nsColor: .windowBackgroundColor) :
                Color.white.opacity(GlassSurface.cardOpacity)))
            .overlay(shape.strokeBorder(GlassAccessibility.increasedContrast(contrast) ? Color.primary.opacity(0.55) : Color.white.opacity(active ? 0.65 : 0.50), lineWidth: GlassAccessibility.increasedContrast(contrast) ? 1.5 : 0.75)
                .allowsHitTesting(false))
            .shadow(color: Color.black.opacity(active ? 0.04 : 0.025), radius: 8, y: 3)
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
                    .fill(Color.white.opacity(0.46))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.27)
                            .fill(color.opacity(0.06))
                    }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.27)
                .strokeBorder(Color.white.opacity(0.65), lineWidth: 0.75))
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
            .accessibilityLabel(L10n.text("真实 OpenVPN 流量趋势"))
            .accessibilityValue(L10n.format("最近 {0} 个采样点；当前 {1} 字节增量", [String(describing: samples.count), String(describing: String(format: "%.0f", samples.last ?? 0))]))
        } else {
            Text(L10n.text("连接后显示趋势"))
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
        .shadow(color: Color.black.opacity(0.06), radius: 5, y: 2)
        .accessibilityLabel("VPN Navigator")
    }
}

