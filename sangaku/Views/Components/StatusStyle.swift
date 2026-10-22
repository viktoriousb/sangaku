import SwiftUI

/// The visual tokens from the mockups. Every colour has a dark-mode variant in the asset catalog.
nonisolated enum ColorToken: String, CaseIterable, Hashable, Sendable {
    case ink, secondaryInk, modelA, modelB, modelC, coauthor
    case verified, verifiedFill, modelChecked, unchecked, delicate, delicateFill, refuted, refutedFill

    var color: Color { Color(rawValue) }
}

nonisolated enum BorderPattern: Hashable, Sendable {
    case solid, dashed, dotted
}

/// How one status looks. The single mapping from status to appearance (invariant 3): border pattern, fill,
/// ink, glyph and label together, so status never rests on colour alone.
nonisolated struct StatusStyle: Hashable, Sendable {
    var border: BorderPattern
    var borderToken: ColorToken
    var fill: ColorToken?
    var ink: ColorToken
    var glyph: String
    var label: String
    /// Unchecked math looks provisional: drawn in `secondaryInk`.
    var isProvisional: Bool
    /// The label where room is short (a node of the statement graph); empty for styles that are never that small.
    var shortLabel = ""
    /// How strongly `fill` is laid on: a neutral tint (the main line) is the ink colour at low opacity.
    var fillOpacity = 1.0
    /// The text it labels is struck through (a citation not found).
    var strikesText = false

    /// The glyph's colour: the border's, except that unchecked grey is too faint for a glyph.
    var glyphToken: ColorToken { borderToken == .unchecked ? .secondaryInk : borderToken }

    static func style(for status: StatementStatus) -> StatusStyle {
        switch status {
        case .formallyVerified:
            StatusStyle(border: .solid, borderToken: .verified, fill: .verifiedFill, ink: .ink,
                        glyph: "⊢", label: "Verified in Lean", isProvisional: false,
                        shortLabel: "Lean-verified")
        case .humanChecked:
            StatusStyle(border: .solid, borderToken: .ink, fill: nil, ink: .ink,
                        glyph: "✓", label: "Checked by a person", isProvisional: false,
                        shortLabel: "Person-checked")
        case .modelChecked:
            StatusStyle(border: .solid, borderToken: .modelChecked, fill: nil, ink: .secondaryInk,
                        glyph: "◐", label: "Checked by a model", isProvisional: true,
                        shortLabel: "Model-checked")
        case .sketched:
            StatusStyle(border: .dashed, borderToken: .unchecked, fill: nil, ink: .secondaryInk,
                        glyph: "◇", label: "Sketched", isProvisional: true, shortLabel: "Sketched")
        case .proposed:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk,
                        glyph: "○", label: "Proposed", isProvisional: true, shortLabel: "Proposed")
        case .refuted:
            StatusStyle(border: .dashed, borderToken: .refuted, fill: .refutedFill, ink: .refuted,
                        glyph: "✗", label: "Refuted", isProvisional: false, shortLabel: "Refuted")
        case .imported:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk,
                        glyph: "↧", label: "Imported, not checked here", isProvisional: true, shortLabel: "Imported")
        }
    }

    /// A referee's verdict on an attempt; nil for an attempt it did not judge. "Complete" is a model's check, so it
    /// is drawn as checked by a model, never as verified; a gap is never drawn as refuted, since only a person
    /// refutes (invariant 1).
    static func style(for verdict: RefereeOutcome?) -> StatusStyle {
        switch verdict {
        case .complete?:
            StatusStyle(border: .solid, borderToken: .modelChecked, fill: nil, ink: .secondaryInk,
                        glyph: "◐", label: "Complete, checked by a model", isProvisional: true)
        case .gap?:
            StatusStyle(border: .dashed, borderToken: .delicate, fill: .delicateFill, ink: .delicate,
                        glyph: "△", label: "Gap found by a model", isProvisional: true)
        case nil:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk,
                        glyph: "–", label: "No verdict", isProvisional: true)
        }
    }

    /// A branch's lifecycle. Being the main line or running is not a lifecycle state: see `style(forBranch:isMain:)`
    /// and `running`.
    static func style(for state: BranchState) -> StatusStyle {
        switch state {
        case .live:
            StatusStyle(border: .solid, borderToken: .ink, fill: nil, ink: .ink,
                        glyph: "○", label: "Live", isProvisional: false)
        case .deadEnd:
            StatusStyle(border: .dashed, borderToken: .unchecked, fill: nil, ink: .secondaryInk,
                        glyph: "×", label: "Dead end", isProvisional: false)
        case .parked:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk,
                        glyph: "‖", label: "Parked", isProvisional: false)
        }
    }

    /// The main line: filled, but in a neutral ink tint and with its own glyph, never a status colour or ✓, so an
    /// adopted proof that nobody has checked never looks checked (invariant 3).
    static let mainLine = StatusStyle(border: .solid, borderToken: .ink, fill: .ink, ink: .ink, glyph: "◆",
                                      label: "Main line", isProvisional: false, fillOpacity: 0.08)

    /// A request is running on the branch. In ink: blue means checked by a model.
    static let running = StatusStyle(border: .solid, borderToken: .ink, fill: nil, ink: .ink, glyph: "●",
                                     label: "Running", isProvisional: false)

    /// A branch's frame: the main line when it is main and live, else its lifecycle.
    static func style(forBranch state: BranchState, isMain: Bool) -> StatusStyle {
        isMain && state == .live ? mainLine : style(for: state)
    }
}

/// The accessibility display settings status drawing depends on.
nonisolated struct StatusAccessibility: Hashable, Sendable {
    var differentiateWithoutColor = false
    var increaseContrast = false
}

/// How a style is drawn under the current accessibility settings.
nonisolated struct StatusPresentation: Hashable, Sendable {
    let style: StatusStyle
    let accessibility: StatusAccessibility

    /// The glyph is always shown: shape carries status even in greyscale.
    var showsGlyph: Bool { true }
    /// The label is always available; Differentiate Without Color promotes it from tooltip to visible text.
    var showsLabelInline: Bool { accessibility.differentiateWithoutColor }
    var borderWidth: Double { accessibility.increaseContrast ? 2 : 1 }

    var dash: [CGFloat] {
        let scale = accessibility.increaseContrast ? 1.5 : 1
        return switch style.border {
        case .solid: []
        case .dashed: [5 * scale, 3 * scale]
        case .dotted: [1.5 * scale, 3 * scale]
        }
    }
}
