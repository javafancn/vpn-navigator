import SwiftUI

/// One type ramp and one control geometry for all five native pages.
enum ReferenceType {
    static let pageTitle: CGFloat = 27
    static let panelTitle: CGFloat = 14
    static let section: CGFloat = 13
    static let field: CGFloat = 13
    static let caption: CGFloat = 11
}
enum ReferenceMetrics {
    static let controlHeight: CGFloat = 32
    static let rowHeight: CGFloat = 35
    static let corner: CGFloat = 9
}

/// Common macOS 13+ form components derived from the six-panel UI reference.
/// The reference's controls are deliberately flatter and more translucent
/// than .roundedBorder defaults. Only presentation is changed here.
struct ReferenceInputChrome: ViewModifier {
    @Environment(\.colorScheme) private var appearance
    var height: CGFloat = ReferenceMetrics.controlHeight
    func body(content: Content) -> some View {
        content
            .font(.system(size: ReferenceType.field, weight: .medium))
            .foregroundStyle(appearance == .dark ? Color.white : GlassPalette.ink)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: ReferenceMetrics.corner, style: .continuous)
                    .fill(appearance == .dark ?
                          Color.white.opacity(0.13) :
                          Color(red: 0.99, green: 0.995, blue: 1).opacity(0.89))
            }
            .overlay {
                RoundedRectangle(cornerRadius: ReferenceMetrics.corner, style: .continuous)
                    .strokeBorder(appearance == .dark ?
                                  Color.white.opacity(0.29) :
                                  Color(red: 0.73, green: 0.82, blue: 0.95).opacity(0.69),
                                  lineWidth: 1)
            }
    }
}

extension View {
    /// Applies the same frosted text/selection container across all pages.
    func referenceInput(height: CGFloat = ReferenceMetrics.controlHeight) -> some View {
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
                    .fill(Color(red: 0.96, green: 0.98, blue: 1).opacity(0.84)))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.96), lineWidth: 1)
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
            .font(.system(size: ReferenceType.caption + 1, weight: .semibold))
            .foregroundStyle(GlassPalette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.68 : 0.91))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.87), lineWidth: 1)
            }
    }
}

 
/// The gradient CTA used in the supplied blue/white reference for import,
/// update, save, and other primary workspace actions.
struct ReferencePrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: ReferenceType.field, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 13)
            .frame(minHeight: 31)
            .background {
                RoundedRectangle(cornerRadius: ReferenceMetrics.corner)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.13, green: 0.58, blue: 1),
                                 Color(red: 0.01, green: 0.40, blue: 0.93)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.46)
            }
            .overlay {
                RoundedRectangle(cornerRadius: ReferenceMetrics.corner)
                    .strokeBorder(Color.white.opacity(0.50), lineWidth: 1)
            }
            .shadow(color: GlassPalette.blue.opacity(isEnabled ? 0.15 : 0),
                    radius: 4, y: 2)
    }
}
