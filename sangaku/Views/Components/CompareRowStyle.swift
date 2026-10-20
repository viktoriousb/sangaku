import Foundation

/// How a row of the comparison looks: glyph, words and border together, so no state rests on colour (invariant 3).
/// A model's "equivalent" is drawn as a model's reading, never in ink and never with a check mark; a divergence is
/// never drawn as a refutation, which only a person makes (invariant 1).
nonisolated enum CompareRowStyle {
    /// `side` names the attempt a one-sided row's step belongs to.
    static func style(for state: RowState, side: Int? = nil) -> StatusStyle {
        switch state {
        case .equivalent:
            StatusStyle(border: .solid, borderToken: .modelChecked, fill: nil, ink: .secondaryInk, glyph: "≡",
                        label: "Equivalent", isProvisional: true)
        case .diverge:
            StatusStyle(border: .dashed, borderToken: .delicate, fill: .delicateFill, ink: .delicate, glyph: "≠",
                        label: "Diverge", isProvisional: true)
        case .onlyOne:
            StatusStyle(border: .solid, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "+",
                        label: side.map { "Only in \(CompareWording.attempt($0))" } ?? "Only in one attempt", isProvisional: true)
        case .notCompared:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "○",
                        label: "Not compared", isProvisional: true)
        case .stale:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "–",
                        label: "Out of date", isProvisional: true)
        }
    }
}
