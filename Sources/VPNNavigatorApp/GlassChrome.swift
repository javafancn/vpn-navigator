import SwiftUI
import AppKit

/// Samples the actual desktop behind the window. Unlike an opaque SwiftUI
/// gradient, this preserves the macOS translucent window appearance.
struct GlassAtmosphere: View {
    var body: some View {
        ZStack {
            DesktopVisualEffect().ignoresSafeArea()
            LinearGradient(colors: [
                Color(red: 0.67, green: 0.81, blue: 1).opacity(0.21),
                Color(red: 0.88, green: 0.77, blue: 0.98).opacity(0.13),
                Color(red: 0.55, green: 0.77, blue: 0.98).opacity(0.17)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
            GeometryReader { proxy in
                Circle()
                    .fill(Color(red: 0.19, green: 0.54, blue: 1).opacity(0.16))
                    .frame(width: 460, height: 460)
                    .blur(radius: 90)
                    .offset(x: proxy.size.width - 260, y: -270)
                Circle()
                    .fill(Color(red: 0.77, green: 0.44, blue: 1).opacity(0.13))
                    .frame(width: 400, height: 400)
                    .blur(radius: 105)
                    .offset(x: -210, y: proxy.size.height - 210)
            }
            .allowsHitTesting(false)
        }
    }
}

struct DesktopVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

private struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(LinearGradient(colors: [
                        Color.white.opacity(0.68),
                        Color.white.opacity(0.16)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 13, y: 4)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
}
