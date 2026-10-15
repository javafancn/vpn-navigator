import SwiftUI
import AppKit

/// The reference's pale blue/pink "alpine glass" is applied inside the window,
/// so appearance does not depend entirely on the user's desktop wallpaper.
enum GlassPalette {
    static let blue = Color(red: 0.05, green: 0.45, blue: 0.98)
    static let cyan = Color(red: 0.10, green: 0.73, blue: 1.0)
    static let ink = Color(red: 0.08, green: 0.14, blue: 0.27)
    static let violet = Color(red: 0.67, green: 0.60, blue: 0.94)
}

private struct MountainRidge: Shape {
    let foreground: Bool
    func path(in rect: CGRect) -> Path {
        let y: CGFloat = foreground ? 0.76 : 0.48
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height * (y + 0.07)))
        let peaks: [(CGFloat, CGFloat)] = foreground ? [
            (0.10, y - 0.08), (0.16, y + 0.01), (0.26, y - 0.15),
            (0.34, y - 0.07), (0.44, y - 0.13), (0.52, y),
            (0.62, y - 0.22), (0.70, y - 0.11), (0.78, y - 0.25),
            (0.86, y - 0.12), (1.00, y - 0.18)
        ] : [
            (0.10, y + 0.06), (0.25, y - 0.11), (0.39, y + 0.02),
            (0.54, y - 0.16), (0.66, y), (0.80, y - 0.29),
            (0.90, y - 0.10), (1.00, y - 0.22)
        ]
        for point in peaks {
            path.addLine(to: CGPoint(x: rect.width * point.0,
                                      y: rect.height * point.1))
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}

struct GlassAtmosphere: View {
    @Environment(\.colorScheme) private var appearance
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DesktopVisualEffect()
                LinearGradient(colors: [
                    Color(red: 0.91, green: 0.95, blue: 1).opacity(0.83),
                    Color(red: 0.88, green: 0.91, blue: 0.99).opacity(0.78),
                    Color(red: 0.97, green: 0.89, blue: 0.96).opacity(0.68),
                    Color(red: 0.81, green: 0.91, blue: 1).opacity(0.82)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
                if appearance == .dark {
                    Color(red: 0.09, green: 0.13, blue: 0.24).opacity(0.77)
                }
                MountainRidge(foreground: false)
                    .fill(LinearGradient(colors: [
                        GlassPalette.cyan.opacity(0.24),
                        GlassPalette.blue.opacity(0.13)
                    ], startPoint: .top, endPoint: .bottom))
                    .blur(radius: 16)
                    .offset(y: geometry.size.height * 0.12)
                MountainRidge(foreground: true)
                    .fill(LinearGradient(colors: [
                        GlassPalette.violet.opacity(0.23),
                        GlassPalette.blue.opacity(0.15)
                    ], startPoint: .top, endPoint: .bottom))
                    .blur(radius: 22)
                    .offset(y: geometry.size.height * 0.07)
                Ellipse()
                    .fill(Color.white.opacity(0.48))
                    .frame(width: 680, height: 270)
                    .blur(radius: 110)
                    .position(x: geometry.size.width * 0.18,
                              y: geometry.size.height * 0.16)
                Ellipse()
                    .fill(GlassPalette.cyan.opacity(0.13))
                    .frame(width: 430, height: 350)
                    .blur(radius: 92)
                    .position(x: geometry.size.width * 0.95,
                              y: geometry.size.height * 0.25)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
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
        return view
    }
    func updateNSView(_ view: NativeWindowGlass, context: Context) {
        view.configureWindow()
    }
}

private struct GlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var appearance
    var cornerRadius: CGFloat
    var active: Bool
    func body(content: Content) -> some View {
        let corners = RoundedRectangle(cornerRadius: cornerRadius,
                                       style: .continuous)
        content
            // The translucent white tint MUST be painted on TOP of the
            // system material. Painting the vibrancy material last produces
            // the flat gray cards seen in earlier hardware screenshots.
            .background {
                corners.fill(LinearGradient(colors: appearance == .dark ? [
                    Color.white.opacity(0.16),
                    Color.white.opacity(0.09)
                ] : [
                    Color.white.opacity(0.79),
                    Color.white.opacity(0.57)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .background(.ultraThinMaterial, in: corners)
            }
            .overlay {
                corners.strokeBorder(LinearGradient(colors: [
                    Color.white.opacity(appearance == .dark ? 0.31 : 0.95),
                    Color.white.opacity(0.28),
                    Color.white.opacity(0.61)
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.15)
            }
            .shadow(color: GlassPalette.blue.opacity(active ? 0.16 : 0.04),
                    radius: active ? 17 : 10, y: 5)
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
            .background(color.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: size * 0.27))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27)
                .strokeBorder(Color.white.opacity(0.72), lineWidth: 1))
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
