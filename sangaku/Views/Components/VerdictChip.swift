import SwiftUI

/// A referee's verdict on one attempt as a chip: glyph and words, so it never rests on colour alone.
struct VerdictChip: View {
    let letter: String
    let outcome: RefereeOutcome?
    var gapSteps: [Int] = []
    var partial = false

    var body: some View {
        var style = StatusStyle.style(for: outcome)
        style.label = Self.text(letter: letter, outcome: outcome, gapSteps: gapSteps, partial: partial)
        return StatusBadge(style: style)
    }

    static func text(letter: String, outcome: RefereeOutcome?, gapSteps: [Int], partial: Bool) -> String {
        let attempt = letter + (partial ? " (partial)" : "")
        return switch outcome {
        case .complete?: "\(attempt): complete"
        case .gap? where gapSteps.isEmpty: "\(attempt): gap"
        case .gap?: "\(attempt): gap at step\(gapSteps.count == 1 ? "" : "s") \(gapSteps.map(String.init).joined(separator: ", "))"
        case nil: "\(attempt): no verdict"
        }
    }
}

#if DEBUG
#Preview("Verdict chips") {
    VStack(alignment: .leading, spacing: 8) {
        VerdictChip(letter: "A", outcome: .complete)
        VerdictChip(letter: "B", outcome: .gap, gapSteps: [5])
        VerdictChip(letter: "C", outcome: nil, partial: true)
    }
    .padding()
}
#endif
