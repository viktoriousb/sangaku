import SwiftUI

/// One numbered step of an attempt: its text, what it establishes, the model's confidence and, when the standing
/// referee verdict lists it, a gap mark. Unchecked math, so its text is drawn provisional (invariant 3).
struct StepRow: View {
    let index: Int
    let text: String
    let establishes: String
    let confidence: Confidence
    /// The letter of the referee whose standing verdict lists this step as a gap.
    var gapListedBy: String?
    /// Set for a step of a finished attempt, which a person can promote to a lemma.
    var promotion: PromotionTarget?
    /// Set for a step of a finished attempt, which a person can review.
    var review: ReviewTarget?

    @Environment(\.promoteSteps) private var promote
    @Environment(\.openReview) private var openReview

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                MathText(text)
                    .foregroundStyle(StatusStyle.style(for: .proposed).ink.color)
                    .textSelection(.enabled)
                if !establishes.isEmpty {
                    MathText("Establishes: " + establishes, showsProblems: false)
                        .captionMath()
                        .foregroundStyle(.secondary)
                }
                if let gapListedBy {
                    let style = StatusStyle.style(for: RefereeOutcome.gap)
                    Label {
                        Text("Listed as a gap by \(gapListedBy)")
                    } icon: {
                        Text(verbatim: style.glyph)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(style.ink.color)
                }
            }
            Spacer(minLength: 4)
            ConfidenceChip(confidence: confidence)
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Copy Step") {
                Pasteboard.copy("Step \(index) (establishes: \(establishes); confidence: \(confidence.rawValue)): \(text)")
            }
            Button("Copy LaTeX Source") { Pasteboard.copy(text) }
            if review != nil || promotion != nil { Divider() }
            if let review, let openReview {
                Button("Review This Step") { openReview(review) }
            }
            if let promotion, let promote {
                Button("Promote to Lemma…") { promote(promotion) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let review, let openReview {
                Button("Review This Step") { openReview(review) }
            }
            if let promotion, let promote {
                Button("Promote to Lemma") { promote(promotion) }
            }
        }
    }
}

#if DEBUG
#Preview("Steps", traits: .fixture, .fixedLayout(width: 420, height: 220)) {
    VStack(alignment: .leading, spacing: 10) {
        StepRow(index: 4, text: #"$q \mid p + 1$ with $q > p$ forces $q = p + 1$."#, establishes: #"Resolve $q \mid p + 1$"#,
                confidence: .delicate)
        StepRow(index: 5, text: #"Since $q > p$, $q$ cannot divide $p + 1$."#, establishes: "q ∤ p + 1",
                confidence: .routine, gapListedBy: "C")
    }
    .padding()
}
#endif
