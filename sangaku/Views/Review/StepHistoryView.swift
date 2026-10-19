import SwiftUI

/// Everything that happened to a step, newest first: versions with their text, reviews, dismissals with their
/// reasons, withdrawals and comments. Collapsed by default. Nothing in it is ever deleted (invariant 7).
struct StepHistoryView: View {
    let step: StepReview
    let authors: AuthorDirectory

    @State private var isExpanded = false

    var body: some View {
        let history = step.history
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(history) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ReviewWording.historyLine(entry, step: step, authors: authors))
                            .font(.caption)
                        if case .version(let version) = entry.kind, !version.isCurrent {
                            MathText(version.textLaTeX)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("History · \(Prose.count(history.count, "event"))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
#Preview("Step history", traits: .fixture, .fixedLayout(width: 520, height: 420)) {
    ReviewPreviewData { state, authors in
        if let step = state.steps.first(where: { $0.index == 5 }) {
            StepHistoryView(step: step, authors: authors)
                .padding()
        }
    }
}
#endif
