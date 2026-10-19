import SwiftUI

extension StatusAccessibility {
    /// The system's settings, unless a preview or test overrides them.
    static func resolve(override: StatusAccessibility?, differentiateWithoutColor: Bool,
                        contrast: ColorSchemeContrast) -> StatusAccessibility {
        override ?? StatusAccessibility(differentiateWithoutColor: differentiateWithoutColor,
                                        increaseContrast: contrast == .increased)
    }
}

/// A status as a capsule: glyph and label. Compact badges show the glyph alone unless colour cannot be relied on
/// (Differentiate Without Color); the label is always the tooltip and what VoiceOver says.
struct StatusBadge: View {
    let style: StatusStyle
    var compact = false

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.statusAccessibilityOverride) private var override

    var body: some View {
        let presentation = StatusPresentation(
            style: style,
            accessibility: .resolve(override: override, differentiateWithoutColor: differentiateWithoutColor, contrast: contrast))
        HStack(spacing: 4) {
            Text(verbatim: style.glyph)
            if !compact || presentation.showsLabelInline {
                Text(style.label)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(style.glyphToken.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(style.fill?.color ?? .clear, in: .capsule)
        .overlay {
            Capsule().strokeBorder(style.borderToken.color,
                                   style: StrokeStyle(lineWidth: presentation.borderWidth, dash: presentation.dash))
        }
        .help(style.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(style.label))
    }
}

/// Frames content in a status's border pattern and fill.
struct StatusFrame: ViewModifier {
    let style: StatusStyle
    var cornerRadius: Double = 10

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.statusAccessibilityOverride) private var override

    func body(content: Content) -> some View {
        let presentation = StatusPresentation(
            style: style,
            accessibility: .resolve(override: override, differentiateWithoutColor: differentiateWithoutColor, contrast: contrast))
        content
            .background(style.fill?.color ?? Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(style.borderToken.color,
                                  style: StrokeStyle(lineWidth: presentation.borderWidth, dash: presentation.dash))
            }
    }
}

extension View {
    func statusFrame(_ style: StatusStyle, cornerRadius: Double = 10) -> some View {
        modifier(StatusFrame(style: style, cornerRadius: cornerRadius))
    }
}

#if DEBUG
#Preview("Status badges") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(StatementStatus.allCases, id: \.self) { status in
            StatusBadge(style: StatusStyle.style(for: status))
        }
        StatusLegend()
        StatusBadge(style: StatusStyle.style(for: .sketched), compact: true)
            .environment(\.statusAccessibilityOverride, StatusAccessibility(differentiateWithoutColor: true, increaseContrast: true))
    }
    .padding()
}
#endif

/// Every statement status with its swatch, glyph and label.
struct StatusLegend: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(StatementStatus.allCases, id: \.self) { status in
                let style = StatusStyle.style(for: status)
                GridRow {
                    Color.clear
                        .frame(width: 22, height: 12)
                        .statusFrame(style, cornerRadius: 3)
                    Text(verbatim: style.glyph)
                        .foregroundStyle(style.glyphToken.color)
                    Text(style.label)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(style.label))
            }
        }
    }
}
