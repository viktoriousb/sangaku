import Foundation

/// How a step's standing looks in Review, in the same family as `StatusStyle`: glyph, words and border together, so
/// no state rests on colour (invariant 3). Chips are never compact. An open ✗ is not drawn as a refuted statement:
/// a person's objection is not a refutation (invariant 1).
nonisolated enum StepReviewStyle {
    static let recheckGlyph = "⚑"

    static var unchecked: StatusStyle {
        StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk,
                    glyph: "○", label: "Not checked by a person", isProvisional: true)
    }

    /// "MK · 11:04": who checked the current version, and when the latest did.
    static func checked(_ label: String) -> StatusStyle {
        StatusStyle(border: .solid, borderToken: .ink, fill: nil, ink: .ink, glyph: "✓", label: label,
                    isProvisional: false)
    }

    /// An open ✗ or ?: "Wrong, open · You".
    static func objection(_ verdict: ReviewVerdict, by names: String) -> StatusStyle {
        let token: ColorToken = verdict == .wrong ? .refuted : .delicate
        return StatusStyle(border: .dashed, borderToken: token, fill: nil, ink: token,
                           glyph: verdict.glyph, label: "\(verdict.title), open · \(names)", isProvisional: true)
    }

    /// What the referee's verdict says about this step's current text; nil when there is no verdict.
    static func model(_ check: ModelCheck, referee letter: String, personChecked: Bool) -> StatusStyle? {
        switch check {
        case .noVerdict:
            return nil
        case .complete:
            return StatusStyle(border: .solid, borderToken: .modelChecked, fill: nil, ink: .secondaryInk, glyph: "◐",
                               label: personChecked ? "Also checked by \(letter)" : "Checked by \(letter) only",
                               isProvisional: true)
        case .gapListed:
            return StatusStyle(border: .dashed, borderToken: .delicate, fill: .delicateFill, ink: .delicate,
                               glyph: "△", label: "Gap found here by \(letter)", isProvisional: true)
        case .attemptHasGap:
            return unseen("\(letter) found a gap elsewhere, so checks nothing here")
        case .revisedSince:
            return unseen("\(letter)'s check covered an earlier version")
        case .unknownBasis:
            return unseen("\(letter)'s check: version unknown")
        }
    }

    /// "Re-check: step 2 changed what it establishes". Counts as checked; it asks for a second look.
    static func recheck(_ recheck: Recheck) -> StatusStyle {
        let steps = recheck.stepIndices
        let which = steps.count == 1 ? "step \(steps[0])" : "steps " + Prose.list(steps.map(String.init))
        return StatusStyle(border: .dashed, borderToken: .delicate, fill: nil, ink: .delicate, glyph: recheckGlyph,
                           label: "Re-check: \(which) changed what \(steps.count == 1 ? "it establishes" : "they establish")",
                           isProvisional: false)
    }

    /// The frame and ink of a step's row: its human standing in border and fill, never in colour alone. Only a
    /// step a person's ✓ counts for is drawn in full ink (invariant 3).
    static func row(_ standing: StepStanding) -> StatusStyle {
        switch standing.human {
        case .checked:
            return StatusStyle(border: .solid, borderToken: .ink, fill: nil, ink: .ink,
                               glyph: ReviewVerdict.correct.glyph, label: "Checked by a person", isProvisional: false)
        case .objected:
            let verdict: ReviewVerdict = standing.openObjections.contains { $0.verdict == .wrong } ? .wrong : .unclear
            return StatusStyle(border: .dashed, borderToken: verdict == .wrong ? .refuted : .delicate,
                               fill: verdict == .wrong ? .refutedFill : .delicateFill, ink: .secondaryInk,
                               glyph: verdict.glyph, label: "Open objection", isProvisional: true)
        case .unchecked:
            return unchecked
        }
    }

    private static func unseen(_ label: String) -> StatusStyle {
        StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "–",
                    label: label, isProvisional: true)
    }
}
