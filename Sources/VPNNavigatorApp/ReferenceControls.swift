import SwiftUI

/// One type ramp and one control geometry for all five native pages.
enum ReferenceType {
    static let pageTitle: CGFloat = 28
    static let panelTitle: CGFloat = 18
    static let section: CGFloat = 16
    static let field: CGFloat = 16
    static let caption: CGFloat = 13
}
enum ReferenceMetrics {
    static let controlHeight: CGFloat = 36
    static let rowHeight: CGFloat = 42
    static let corner: CGFloat = 8
}

/// Common macOS 13+ form components derived from the six-panel UI reference.
/// The reference's controls are deliberately flatter and more translucent
/// than .roundedBorder defaults. Only presentation is changed here.
struct ReferenceInputChrome: ViewModifier {
    @Environment(\.colorScheme) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var height: CGFloat = ReferenceMetrics.controlHeight
    var focused = false
    func body(content: Content) -> some View {
        content
            .font(.system(size: ReferenceType.field))
            .foregroundStyle(appearance == .dark ? Color.white : GlassPalette.ink)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: ReferenceMetrics.corner, style: .continuous)
                    .fill(GlassAccessibility.increasedContrast(contrast) ? Color(nsColor: .textBackgroundColor) : appearance == .dark ?
                          Color.white.opacity(0.13) :
                          Color.white.opacity(focused ? 0.40 : 0.28))
            }
            .overlay {
                RoundedRectangle(cornerRadius: ReferenceMetrics.corner, style: .continuous)
                    .strokeBorder(focused ? GlassPalette.blue.opacity(0.65) :
                        GlassAccessibility.increasedContrast(contrast) ? Color.primary.opacity(0.65) : Color.white.opacity(appearance == .dark ? 0.25 : 0.48),
                        lineWidth: focused || GlassAccessibility.increasedContrast(contrast) ? 1.5 : 0.75)
                    .allowsHitTesting(false)
            }
            .tint(GlassPalette.blue)
            .animation(GlassMotion.feedback(reduceMotion), value: focused)
    }
}

extension View {
    /// Applies the same frosted text/selection container across all pages.
    func referenceInput(height: CGFloat = ReferenceMetrics.controlHeight, focused: Bool = false) -> some View {
        modifier(ReferenceInputChrome(height: height, focused: focused))
    }
}

/// Compact line of metadata in the design's profile and routing inspectors.
struct ReferenceDetailRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 9) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 65, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(minHeight: 19)
        .accessibilityElement(children: .combine)
    }
}

/// Uniform visual container for the reference's segmented inspector tabs.
struct ReferenceSegmentChrome: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(GlassAccessibility.increasedContrast(contrast) ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.16)))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(GlassAccessibility.increasedContrast(contrast) ? Color.primary.opacity(0.55) : Color.white.opacity(0.42), lineWidth: GlassAccessibility.increasedContrast(contrast) ? 1.5 : 0.75)
            }
    }
}

extension View {
    func referenceSegments() -> some View { modifier(ReferenceSegmentChrome()) }
}

/// Distinct field label column. Avoids the inconsistent native form offsets
/// visible in the old implementation across configuration and diagnostics.
struct ReferenceFormRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 65, alignment: .leading)
            content.accessibilityLabel(Text(title))
        }
        .frame(minHeight: 29)
    }
}

/// State changes animate only on interaction. There is no idle glow/timer.
enum GlassMotion {
    static func feedback(_ reduced: Bool) -> Animation? {
        reduced ? nil : .easeOut(duration: 0.12)
    }
    static func selection(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(response: 0.30, dampingFraction: 0.88)
    }
    static func page(_ reduced: Bool) -> Animation? {
        reduced ? nil : .easeOut(duration: 0.16)
    }
}

struct ReferenceSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ReferenceButtonBody(label: configuration.label,
            pressed: configuration.isPressed, primary: false)
    }
}

struct ReferencePrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ReferenceButtonBody(label: configuration.label,
            pressed: configuration.isPressed, primary: true)
    }
}

private struct ReferenceButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isFocused) private var keyboardFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ReferenceMetrics.corner, style: .continuous)
        label
            .font(.system(size: primary ? ReferenceType.field : ReferenceType.caption + 1,
                          weight: .medium))
            .foregroundStyle(primary ? Color.white : GlassPalette.ink)
            .padding(.horizontal, primary ? 13 : 12)
            .frame(minHeight: primary ? 36 : 34)
            .background {
                if primary {
                    shape.fill(LinearGradient(colors: [
                        Color(red: 0.08, green: 0.55, blue: 1), GlassPalette.blue
                    ], startPoint: .top, endPoint: .bottom))
                } else {
                    shape.fill(GlassAccessibility.increasedContrast(contrast) ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(pressed ? 0.22 : hovered && enabled ? 0.46 : 0.30))
                }
            }
            .overlay(shape.strokeBorder(keyboardFocused ? GlassPalette.blue : GlassAccessibility.increasedContrast(contrast) ? Color.primary.opacity(0.65) : Color.white.opacity(primary ? 0.40 : 0.55), lineWidth: keyboardFocused ? 2 : GlassAccessibility.increasedContrast(contrast) ? 1.5 : 0.75)
                .allowsHitTesting(false))
            .shadow(color: Color.black.opacity(primary && enabled ? 0.07 : 0.015), radius: 4, y: 2)
            .brightness(primary && hovered && enabled ? 0.035 : 0)
            .opacity(enabled ? pressed ? 0.88 : 1 : GlassAccessibility.increasedContrast(contrast) ? 0.65 : 0.45)
            .scaleEffect(pressed && !reduceMotion ? 0.985 : 1)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(GlassMotion.feedback(reduceMotion), value: hovered)
            .animation(GlassMotion.feedback(reduceMotion), value: pressed)
    }
}

/// Navigation, list and icon buttons keep their own geometry/material.
/// Feedback does not reflow neighbouring controls or capture text-field focus.
struct ReferenceQuietButton: ButtonStyle {
    var cornerRadius: CGFloat = 9
    var hoverOpacity: Double = 0.12
    func makeBody(configuration: Configuration) -> some View {
        ReferenceQuietButtonBody(label: configuration.label, pressed: configuration.isPressed,
            cornerRadius: cornerRadius, hoverOpacity: hoverOpacity)
    }
}

private struct ReferenceQuietButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let cornerRadius: CGFloat
    let hoverOpacity: Double
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var keyboardFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var body: some View {
        label
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(hovered && enabled ? hoverOpacity : 0)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(
                keyboardFocused ? GlassPalette.blue : .clear, lineWidth: 2).allowsHitTesting(false))
            .opacity(pressed ? 0.82 : 1)
            .scaleEffect(pressed && !reduceMotion ? 0.992 : 1)
            .onHover { hovered = $0 }
            .animation(GlassMotion.feedback(reduceMotion), value: hovered)
            .animation(GlassMotion.feedback(reduceMotion), value: pressed)
    }
}
