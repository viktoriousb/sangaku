import SwiftUI

/// Review's side panel: the Lean checks of the statements resting on this attempt, the attempt's citations, the
/// computations run on those statements, and export with the AI-use statement. Its words never say more than
/// the statuses do (invariants 3, 6 and 8).
struct VerificationPanel: View {
    let problem: Problem
    let attempt: ProofAttempt
    let graph: StatementGraphState?
    let verification: VerificationState
    let citations: [CitationFact]
    let currentStepID: UUID?
    let authors: AuthorDirectory

    var body: some View {
        // The statements whose source steps are in this attempt, in graph order.
        let statements = (graph?.nodes ?? []).filter { node in node.sources.contains { $0.attemptID == attempt.stableID } }
        VStack(alignment: .leading, spacing: 16) {
            LeanPanelCard(problem: problem, statements: statements, verification: verification, authors: authors)
            CitationsPanelCard(attempt: attempt, facts: citations, currentStepID: currentStepID)
            EvidencePanelCard(statements: statements, verification: verification, authors: authors)
            ExportCard(problem: problem, graph: graph ?? .empty, verification: verification)
        }
    }
}

/// A titled card of the panel.
struct PanelCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Each statement's Lean check: where it stands, sorries and axioms, the versions it ran with, the person's
/// confirmation, and what can be done next.
private struct LeanPanelCard: View {
    let problem: Problem
    let statements: [StatementNode]
    let verification: VerificationState
    let authors: AuthorDirectory

    @Environment(\.leanService) private var lean
    @Environment(\.verificationActions) private var actions

    var body: some View {
        // Read once for every row.
        let failures = lean?.lastFailure ?? [:]
        PanelCard(title: "Lean") {
            if statements.isEmpty {
                Text("No statement rests on this attempt's steps yet; promote steps to formalize them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let lean, lean.isChecking(problem: problem.stableID) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Lean is checking this problem's module.").font(.callout)
                    Button("Stop") { actions?(.stopLean(problem: problem.stableID)) }
                        .disabled(actions == nil)
                }
            }
            ForEach(statements) { node in
                if let facts = verification.lean[node.id] {
                    LeanStatementRow(facts: facts, failure: failures[node.id], authors: authors)
                }
            }
        }
    }
}

/// One statement in the Lean card.
private struct LeanStatementRow: View {
    let facts: LeanFacts
    let failure: String?
    let authors: AuthorDirectory

    @Environment(\.verificationActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(facts.label).font(.callout.weight(.semibold))
                StatusBadge(style: StatusStyle.style(for: facts.standing))
            }
            if facts.source != nil {
                if let sorries = VerificationWording.sorries(facts.sorryLocations) { Text(sorries).font(.caption) }
                Text(VerificationWording.axioms(facts)).font(.caption).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(facts.errors.prefix(3).enumerated()), id: \.offset) { _, error in
                    Text(verbatim: "Line \(error.line): \(error.text)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ColorToken.delicate.color)
                        .lineLimit(3)
                }
                HStack(spacing: 6) {
                    StatusBadge(style: StatusStyle.style(for: facts.fidelity), compact: true)
                    Text(VerificationWording.fidelity(facts.fidelity, label: facts.label, authors: authors)).font(.caption)
                }
                if let checked = VerificationWording.checked(facts, authors: authors) {
                    Text(checked)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let source = facts.source {
                    DisclosureGroup("Lean statement") { ToolTextBox(text: source.statementPart, label: "Lean statement") }
                        .font(.caption)
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(ColorToken.delicate.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Button("Formalize…") { actions?(.formalize(statement: facts.statementID)) }
                if facts.source != nil {
                    Button("Check Again…") {
                        actions?(.checkLean(statement: facts.statementID, candidate: .current, editing: false))
                    }
                    Button("Edit…") { actions?(.checkLean(statement: facts.statementID, candidate: .current, editing: true)) }
                    Button("Confirm Statement…") { actions?(.confirmStatement(facts.statementID)) }
                    if let reviewer = facts.fidelity.reviewer, reviewer == authors.meID {
                        Button("Withdraw My Review") { actions?(.withdrawFidelity(statement: facts.statementID)) }
                            .help("Take back your review of this Lean statement; it stays in the history")
                    }
                }
            }
            .controlSize(.small)
            .disabled(actions == nil)
        }
    }
}

/// The attempt's citations by step, with what each lookup found, and Check, Add and Remove.
private struct CitationsPanelCard: View {
    let attempt: ProofAttempt
    let facts: [CitationFact]
    let currentStepID: UUID?

    @Environment(\.verificationActions) private var actions
    @Environment(\.citationService) private var citations

    var body: some View {
        let checking = !(citations?.checking.isEmpty ?? true)
        PanelCard(title: "Citations") {
            if facts.isEmpty {
                Text("No step of this attempt cites anything.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(facts) { fact in
                CitationRow(fact: fact)
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Button("Check Citations…") { actions?(.checkCitations(attempt: attempt.stableID)) }
                    .disabled(actions == nil || facts.isEmpty || checking)
                Button("Add to Current Step…") { if let currentStepID { actions?(.addCitation(step: currentStepID)) } }
                    .disabled(actions == nil || currentStepID == nil)
            }
            .controlSize(.small)
            if checking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Looking citations up.").font(.callout)
                    Button("Stop") { actions?(.stopCitations) }
                        .disabled(actions == nil)
                }
            }
        }
    }
}

/// One citation in the card: its step, the citation as its status draws it, what the last lookup found, and Remove.
private struct CitationRow: View {
    let fact: CitationFact

    @Environment(\.verificationActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Step \(fact.stepIndex)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            CitationLine(fact: fact)
            if let lookup = VerificationWording.lookup(fact) {
                Text(lookup).font(.caption).foregroundStyle(.secondary)
            }
            Button("Remove") { actions?(.removeCitation(fact.id)) }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(actions == nil)
        }
    }
}

/// The computations run on the statements resting on this attempt, newest first, and Ask for a Check.
private struct EvidencePanelCard: View {
    let statements: [StatementNode]
    let verification: VerificationState
    let authors: AuthorDirectory

    @Environment(\.verificationActions) private var actions

    var body: some View {
        let runs = statements.flatMap { node in (verification.evidence[node.id] ?? []).map { (node.label, $0) } }
        PanelCard(title: "Evidence") {
            if runs.isEmpty {
                Text("No computation has run on these statements.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(runs, id: \.1.id) { label, fact in
                EvidenceRow(label: label, fact: fact, authors: authors)
            }
            if !statements.isEmpty {
                Menu("Ask for a Check…") {
                    ForEach(statements) { node in
                        Button(node.label) {
                            actions?(.askForCheck(ScoutSeed(claim: node.statementLaTeX, statements: [node.id])))
                        }
                        Button("Write My Own for \(node.label)…") { actions?(.writeCell(statement: node.id, basedOn: nil)) }
                    }
                }
                .fixedSize()
                .disabled(actions == nil)
            }
        }
    }
}

/// One run in the card: the statement and tool, then how it ended.
private struct EvidenceRow: View {
    let label: String
    let fact: EvidenceFact
    let authors: AuthorDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label) · \(ToolID(fact.tool).displayName)").font(.caption.weight(.semibold))
            RunSummary(fact: fact, authors: authors)
        }
    }
}
