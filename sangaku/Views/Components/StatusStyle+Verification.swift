import Foundation

/// The looks of Lean checks, fidelity reviews, computations and citations (invariant 3): each a glyph, a label, a border
/// pattern and an ink, never colour alone. Only the derived "verified in Lean" uses ⊢; compiling without a person's
/// confirmation stays provisional; a counterexample a tool reports, a failed check and a citation not found are drawn
/// as things to look at, never as refuted, since only a person refutes (invariant 1).
nonisolated extension StatusStyle {
    static func style(for standing: LeanStanding) -> StatusStyle {
        switch standing {
        case .verified:
            style(for: .formallyVerified)
        case .notChecked:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "□",
                        label: "No Lean check", isProvisional: true)
        case .didNotCompile:
            StatusStyle(border: .dashed, borderToken: .delicate, fill: .delicateFill, ink: .delicate, glyph: "⊘",
                        label: "Lean reports errors", isProvisional: true)
        case .namesUnusedStatement:
            StatusStyle(border: .dashed, borderToken: .delicate, fill: .delicateFill, ink: .delicate, glyph: "↗",
                        label: "Names a statement it does not use", isProvisional: true)
        case .axiomCheckMissing:
            StatusStyle(border: .dashed, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "⊡",
                        label: "Axiom check did not report", isProvisional: true)
        case .incomplete:
            StatusStyle(border: .dashed, borderToken: .delicate, fill: .delicateFill, ink: .delicate, glyph: "⋯",
                        label: "Compiles with sorry or other axioms", isProvisional: true)
        case .awaitingFidelity:
            StatusStyle(border: .dashed, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "◈",
                        label: "Compiles; statement not yet confirmed", isProvisional: true)
        case .statementDiffers:
            StatusStyle(border: .dashed, borderToken: .delicate, fill: .delicateFill, ink: .delicate, glyph: "≠",
                        label: "Lean statement differs", isProvisional: true)
        }
    }

    static func style(for fidelity: FidelityStanding) -> StatusStyle {
        switch fidelity {
        case .pending:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "◌",
                        label: "Statement not yet confirmed", isProvisional: true)
        case .confirmed:
            StatusStyle(border: .solid, borderToken: .ink, fill: nil, ink: .ink, glyph: "✓",
                        label: "Statement confirmed by a person", isProvisional: false)
        case .differs:
            StatusStyle(border: .dashed, borderToken: .delicate, fill: .delicateFill, ink: .delicate, glyph: "≠",
                        label: "A person found the statements differ", isProvisional: true)
        case .outdated:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "–",
                        label: "Confirmed for an earlier version", isProvisional: true)
        }
    }

    static func style(for cell: CellState) -> StatusStyle {
        switch cell {
        case .waiting:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "▷",
                        label: "Waiting for your Run", isProvisional: true)
        case .running:
            running
        case .ran(let outcome, let verdict):
            style(outcome: outcome, verdict: verdict)
        }
    }

    /// A run of a computation: what its code reported when it completed, else how it ended.
    static func style(outcome: RunOutcome, verdict: CellVerdict) -> StatusStyle {
        switch (outcome, verdict) {
        case (.completed, .holds):
            StatusStyle(border: .dashed, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "∅",
                        label: "No counterexample in the tested scope", isProvisional: true)
        case (.completed, .counterexample):
            StatusStyle(border: .dashed, borderToken: .delicate, fill: .delicateFill, ink: .delicate, glyph: "▲",
                        label: "Counterexample reported, not accepted", isProvisional: true)
        case (.completed, .inconclusive):
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "∼",
                        label: "Inconclusive", isProvisional: true)
        case (.exitedNonzero, _):
            StatusStyle(border: .dotted, borderToken: .delicate, fill: nil, ink: .delicate, glyph: "!",
                        label: "The run failed", isProvisional: true)
        case (.timedOut, _):
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "⧗",
                        label: "Ran out of time", isProvisional: true)
        case (.memoryLimit, _):
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "⇡",
                        label: "Ran out of memory", isProvisional: true)
        case (.diskLimit, _):
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "⊞",
                        label: "Wrote too much", isProvisional: true)
        case (.stopped, _):
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "■",
                        label: "Stopped", isProvisional: true)
        case (.couldNotRun, _):
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "⊝",
                        label: "Could not run", isProvisional: true)
        }
    }

    /// A citation (invariant 6). A found one says only that a matching document exists; one not found is struck
    /// through; an unchecked one has no link.
    static func style(for citation: CitationStatus) -> StatusStyle {
        switch citation {
        case .unverified:
            StatusStyle(border: .dotted, borderToken: .unchecked, fill: nil, ink: .secondaryInk, glyph: "?",
                        label: "Not checked", isProvisional: true)
        case .found:
            StatusStyle(border: .solid, borderToken: .ink, fill: nil, ink: .ink, glyph: "↗",
                        label: "A matching document was found", isProvisional: false)
        case .notFound:
            StatusStyle(border: .dashed, borderToken: .delicate, fill: .delicateFill, ink: .delicate, glyph: "∄",
                        label: "Not found in arXiv or zbMATH Open", isProvisional: true, strikesText: true)
        }
    }
}
