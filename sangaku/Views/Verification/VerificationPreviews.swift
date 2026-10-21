#if DEBUG
import SwiftData
import SwiftUI

/// Hands a preview the verification fixture's problem, a window showing it, and its people.
private struct VerifiedProblem<Content: View>: View {
    @Query private var problems: [Problem]
    @Query private var people: [Person]
    @State private var window = WindowState()
    let content: (Problem, WindowState, AuthorDirectory) -> Content

    init(@ViewBuilder content: @escaping (Problem, WindowState, AuthorDirectory) -> Content) {
        self.content = content
    }

    var body: some View {
        if let problem = problems.first {
            content(problem, window, AuthorDirectory(problem: problem, people: people, catalog: .standard))
                .verificationSheets(window: window)
                .onAppear { window.select(problem: problem) }
        }
    }
}

private func statement(_ label: String, in problem: Problem) -> Statement? {
    (problem.statements ?? []).first { $0.label == label }
}

#Preview("Review with verification", traits: .verifiedFixture, .fixedLayout(width: 1240, height: 1100)) {
    VerifiedProblem { problem, window, _ in
        ReviewView(problem: problem, window: window)
    }
}

#Preview("Review, panel below, dark", traits: .verifiedFixture, .fixedLayout(width: 640, height: 1400)) {
    VerifiedProblem { problem, window, _ in
        ReviewView(problem: problem, window: window)
    }
    .preferredColorScheme(.dark)
}

#Preview("Cells and a Lean draft in the thread", traits: .verifiedFixture, .fixedLayout(width: 720, height: 1400)) {
    VerifiedProblem { problem, _, authors in
        let messages = (problem.mainBranch?.sortedMessages ?? []).filter { $0.kind == .compute || $0.kind == .leanDraft }
        ScrollView {
            VStack(spacing: 16) {
                ForEach(messages, id: \.stableID) { message in
                    MessageRow(message: message, stream: nil, authors: authors, onViewContext: { _ in }, onStop: {})
                }
            }
            .padding()
        }
    }
}

#Preview("Check sheet", traits: .verifiedFixture, .sizeThatFitsLayout) {
    VerifiedProblem { problem, _, _ in
        if let lemma = statement("Lem 3", in: problem) {
            LeanCheckSheet(problem: problem, statement: lemma, candidate: .current, startsEditing: false)
        }
    }
}

#Preview("Check sheet, editing", traits: .verifiedFixture, .sizeThatFitsLayout) {
    VerifiedProblem { problem, _, _ in
        if let lemma = statement("Lem 6", in: problem),
           let draft = (problem.mainBranch?.sortedMessages ?? []).first(where: { $0.leanDraft != nil }) {
            LeanCheckSheet(problem: problem, statement: lemma, candidate: .draft(messageID: draft.stableID),
                           startsEditing: true)
        }
    }
}

#Preview("Confirm statement, dark", traits: .verifiedFixture, .sizeThatFitsLayout) {
    VerifiedProblem { problem, _, _ in
        if let lemma = statement("Lem 2", in: problem) { FidelitySheet(problem: problem, statement: lemma) }
    }
    .preferredColorScheme(.dark)
}

#Preview("Ask for a check", traits: .verifiedFixture, .sizeThatFitsLayout) {
    VerifiedProblem { problem, window, _ in
        if let lemma = statement("Lem 3", in: problem), let branch = window.selectedBranch(in: problem) {
            ScoutSheet(problem: problem, seed: ScoutSeed(claim: lemma.statementLaTeX, statements: [lemma.stableID]), branch: branch)
        }
    }
}

#Preview("Formalize", traits: .verifiedFixture, .sizeThatFitsLayout) {
    VerifiedProblem { problem, window, _ in
        if let lemma = statement("Lem 6", in: problem), let branch = window.selectedBranch(in: problem) {
            FormalizeSheet(problem: problem, statement: lemma, branch: branch)
        }
    }
}

#Preview("Accept refutation", traits: .verifiedFixture, .sizeThatFitsLayout) {
    VerifiedProblem { problem, _, _ in
        if let claim = statement("Claim 2", in: problem), let run = claim.evidence?.first {
            RefutationSheet(problem: problem, statement: claim, evidence: run)
        }
    }
}

#Preview("Check citations", traits: .verifiedFixture, .sizeThatFitsLayout) {
    VerifiedProblem { problem, _, _ in
        if let attempt = (problem.mainBranch?.sortedMessages ?? []).lazy.compactMap(\.proofAttempt).first {
            CitationCheckSheet(attempt: attempt)
        }
    }
}

#Preview("Add a citation", traits: .verifiedFixture, .sizeThatFitsLayout) {
    VerifiedProblem { problem, _, _ in
        if let step = (problem.mainBranch?.sortedMessages ?? []).lazy.compactMap(\.proofAttempt).first?.sortedSteps.first {
            CitationAddSheet(step: step)
        }
    }
}

#Preview("A refusal, and a request under way", traits: .verifiedFixture, .fixedLayout(width: 640, height: 260)) {
    VerifiedProblem { _, window, _ in
        VStack(alignment: .leading, spacing: 16) {
            VerificationNoticeBanner(window: window)
            TaskStreamingBody(kind: .leanDraft, stream: MessageStream())
                .padding(.horizontal)
            Spacer()
        }
        .onAppear { window.verificationNotice = VerificationWording.waitsWhileBlind }
    }
}

#Preview("Long code, every line kept", traits: .sizeThatFitsLayout) {
    ToolTextBox(text: (1...400).map { "line \($0): x_\($0) = x_\($0 - 1) + \($0)" }.joined(separator: "\n"),
                label: "Code", copyTitle: "Copy Code")
        .frame(width: 520)
        .padding()
}

#Preview("A person's computation", traits: .verifiedFixture, .sizeThatFitsLayout) {
    VerifiedProblem { problem, window, _ in
        if let lemma = statement("Lem 3", in: problem), let branch = window.selectedBranch(in: problem) {
            CellEditorSheet(problem: problem, statement: lemma, basedOn: nil, branch: branch)
        }
    }
}
#endif
