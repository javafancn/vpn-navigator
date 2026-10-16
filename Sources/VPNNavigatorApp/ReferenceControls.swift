import SwiftUI

/// Common macOS 13+ form components derived from the six-panel UI reference.
/// The reference's controls are deliberately flatter and more translucent
/// than .roundedBorder defaults. Only presentation is changed here.
struct ReferenceInputChrome: ViewModifier {
    @Environment(\.colorScheme) private var appearance
    var height: CGFloat = 29
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(appearance == .dark ? Color.white : GlassPalette.ink)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(appearance == .dark ?
                          Color.white.opacity(0.10) : Color.white.opacity(0.59))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(appearance == .dark ? 0.27 : 0.86),
                                  lineWidth: 1)
            }
    }
}

extension View {
    /// Applies the same frosted text/selection container across all pages.
    func referenceInput(height: CGFloat = 29) -> some View {
        modifier(ReferenceInputChrome(height: height))
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
        .font(.system(size: 11))
        .frame(minHeight: 19)
    }
}

/// Uniform visual container for the reference's segmented inspector tabs.
struct ReferenceSegmentChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(GlassSurface.panel.opacity(0.46)))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.70), lineWidth: 1)
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 65, alignment: .leading)
            content
        }
        .frame(minHeight: 29)
    }
}

/// Consistent emphasis for the small auxiliary call-to-action buttons.
struct ReferenceSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(GlassPalette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 27)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.40 : 0.62))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.87), lineWidth: 1)
            }
    }
}
