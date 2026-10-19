import SwiftData
import SwiftUI

/// The pinned problem: the statement every model sees, with the displayed status of its theorem (after the cap by
/// what the theorem uses, invariant 13) and, when it is held down, why.
struct PinnedProblemCard: View {
    let problem: Problem
    let onEdit: () -> Void

    @Environment(\.statementGraph) private var graph
    @Environment(\.mathContext) private var mathContext
    @Query private var people: [Person]

    var body: some View {
        let theorem = graph?.state(for: problem, people: Set(people.map(\.stableID))).pinned
        let status = theorem?.derived.displayed
        let style = StatusStyle.style(for: status ?? .proposed)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("PINNED PROBLEM")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text("· in every model's context")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let status {
                    StatusBadge(style: StatusStyle.style(for: status))
                }
                Button("Edit", action: onEdit)
                    .buttonStyle(.borderless)
                    .help("Edit the title and statement")
            }
            if problem.statementLaTeX.isEmpty {
                Text("No statement yet. Edit the problem to pin one.")
                    .foregroundStyle(.secondary)
            } else {
                // Unchecked math looks provisional (invariant 3): the status decides the ink.
                MathText(problem.statementLaTeX)
                    .environment(\.mathContext, MathContext(macros: mathContext.macros, fontSize: 18))
                    .foregroundStyle(style.ink.color)
                    .textSelection(.enabled)
            }
            if let theorem {
                StatusExplanationLines(explanation: theorem.explanation)
            }
        }
        .padding(18)
        .statusFrame(style)
        .contextMenu {
            Button("Edit Problem…", action: onEdit)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned problem")
    }
}

#if DEBUG
#Preview("Pinned problem", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first {
        PinnedProblemCard(problem: problem, onEdit: {})
            .padding()
            .frame(width: 760)
    }
}
#endif
