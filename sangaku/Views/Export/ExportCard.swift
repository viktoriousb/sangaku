import AppKit
import SwiftData
import SwiftUI

/// Review's export card: the AI-use statement for the theorem and what it uses, exactly as the exports write it
/// (invariant 8), the three exports, and how the last one ended. Its own view, so its reads are tracked apart from the
/// panel's step selection.
struct ExportCard: View {
    let problem: Problem
    /// Read by Review for the same people; the card does not read them again.
    let graph: StatementGraphState
    let verification: VerificationState

    @Query private var people: [Person]
    @Environment(\.exportService) private var export
    @Environment(\.exportActions) private var actions

    var body: some View {
        let snapshot = ExportSnapshot.read(problem: problem, people: Set(people.map(\.stableID)), graph: graph,
                                           verification: verification)
        let statement = AIUseStatement.of(snapshot, scope: .theoremAndUses)
        let problemID = problem.stableID
        PanelCard(title: "Export") {
            Text(AIUseStatement.heading).font(.subheadline.weight(.semibold))
            ForEach(Array(statement.paragraphMarkups.enumerated()), id: \.offset) { _, paragraph in
                MathText(paragraph)
                    .captionMath()
                    .textSelection(.enabled)
            }
            Text(ExportScreenWording.aiUseCaption(theorem: snapshot.theorem?.label))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy Statement") { Pasteboard.copy(statement.markup) }
                .help("Copies the statement as shown, with any mathematics in LaTeX.")
            Divider()
            if let phase = export?.phases[problemID] {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(phase.words).font(.callout)
                    Spacer()
                    Button("Stop Export") { actions?(.stop(problem: problemID)) }
                }
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(ExportKind.allCases) { kind in
                        Button(kind.title + "…") { actions?(.open(kind)) }
                            .disabled(actions == nil)
                    }
                }
            }
            if let outcome = export?.outcomes[problemID] {
                ExportOutcomeLine(outcome: outcome)
            }
        }
    }
}

/// How the last export ended, with its report and its folder.
private struct ExportOutcomeLine: View {
    let outcome: ExportOutcome

    @Environment(\.exportActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ExportScreenWording.outcome(outcome),
                  systemImage: outcome.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(outcome.succeeded ? Color.primary : ColorToken.refuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                if outcome.report != nil || !outcome.succeeded {
                    Button("Show Report…") { actions?(.showReport) }
                }
                if outcome.succeeded {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outcome.folder)])
                    }
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last export")
    }
}

#if DEBUG
#Preview("Export card", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query var people: [Person]
    ScrollView {
        if let problem = problems.first {
            let ids = Set(people.map(\.stableID))
            ExportCard(problem: problem, graph: .read(problem: problem, people: ids),
                       verification: .read(problem: problem, people: ids)).padding()
        }
    }
    .frame(width: 380, height: 700)
}
#endif
