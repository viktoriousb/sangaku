import SwiftUI

/// The selected statement: what it says, its displayed status and what holds it down, what it uses and is used
/// by (as buttons that select them), its delicate steps and who wrote it.
struct StatementDetail: View {
    let node: StatementNode
    let state: StatementGraphState
    let problem: Problem
    let authors: AuthorDirectory
    /// The statement's Lean check and its runs, newest first, read by the parent.
    let lean: LeanFacts?
    let runs: [EvidenceFact]
    let onSelect: (UUID) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// Opens Review on the statement's source steps.
    let onReview: () -> Void

    @Environment(\.verificationActions) private var verification

    @Environment(\.statementGraph) private var graph
    @State private var failure: String?

    var body: some View {
        let style = StatusStyle.style(for: node.derived.displayed)
        VStack(alignment: .leading, spacing: 12) {
            Text("SELECTED")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(StatementLabels.heading(node.label, kind: node.kind) + ".").fontWeight(.semibold)
                // Unchecked math looks provisional (invariant 3): the displayed status decides the ink.
                MathText(node.statementLaTeX)
                    .foregroundStyle(style.ink.color)
                    .textSelection(.enabled)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    heading("Status")
                    status(style)
                }
                GridRow {
                    heading("Uses")
                    uses
                }
                GridRow {
                    heading("Used by")
                    links(node.usedBy, empty: "Nothing yet")
                }
                GridRow {
                    heading("Watch")
                    watch
                }
                GridRow {
                    heading("Written by")
                    Text(authors.name(of: node.author))
                }
                if let facts = lean {
                    GridRow {
                        heading("Lean")
                        VStack(alignment: .leading, spacing: 2) {
                            StatusBadge(style: StatusStyle.style(for: facts.standing))
                            if facts.source != nil {
                                Text([VerificationWording.sorries(facts.sorryLocations), VerificationWording.axioms(facts)]
                                    .compactMap { $0 }.joined(separator: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if let latest = runs.first {
                    GridRow {
                        heading("Checks")
                        VStack(alignment: .leading, spacing: 2) {
                            StatusBadge(style: StatusStyle.style(outcome: latest.outcome, verdict: latest.verdict), compact: true)
                            MathText(VerificationWording.runCount(runs.count) + VerificationWording.run(latest))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .font(.callout)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(ColorToken.refuted.color)
            }
            actions
        }
        .onChange(of: node.id) { failure = nil }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    private func status(_ style: StatusStyle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            FlowLayout(spacing: 6, lineSpacing: 4) {
                StatusBadge(style: style)
                if !node.sources.isEmpty {
                    Text("from \(node.sourceSummary(letter: letter))")
                        .foregroundStyle(.secondary)
                }
            }
            if node.derived.isCapped {
                Text("Its own status: \(StatusStyle.style(for: node.derived.own).label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let source = node.importedSource {
                Text(StatementWording.imported(source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            StatusExplanationLines(explanation: node.explanation)
        }
    }

    private var uses: some View {
        VStack(alignment: .leading, spacing: 4) {
            if node.uses.isEmpty {
                Text("Nothing").foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 4) {
                    ForEach(node.uses, id: \.self) { id in
                        let label = state.label(of: id)
                        HStack(spacing: 3) {
                            StatementLink(label: label) { onSelect(id) }
                            Button("Remove", systemImage: "xmark.circle.fill") { remove(id) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Remove \(label) from what \(node.label) uses")
                                .accessibilityLabel("Remove \(label) from what \(node.label) uses")
                        }
                    }
                }
            }
            let candidates = node.importedSource == nil ? state.candidates(toUse: node.id) : []
            if node.importedSource != nil {
                Text(StatementError.importedCannotUse.message).font(.caption).foregroundStyle(.secondary)
            } else if !candidates.isEmpty {
                Menu("Add Dependency") {
                    ForEach(candidates) { candidate in
                        Button(candidate.label) { add(candidate.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Only statements that would not make \(node.label) depend on itself are offered")
            }
        }
    }

    private func links(_ ids: [UUID], empty: String) -> some View {
        Group {
            if ids.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 4) {
                    ForEach(ids, id: \.self) { id in
                        StatementLink(label: state.label(of: id)) { onSelect(id) }
                    }
                }
            }
        }
    }

    private var watch: some View {
        Group {
            let delicate = node.delicateSources
            if delicate.isEmpty {
                Text("No delicate steps").foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    ForEach(delicate, id: \.stepID) { source in
                        Text("\(letter(source.attemptAuthor))·\(source.index)")
                    }
                    ConfidenceChip(confidence: .delicate)
                }
            }
        }
    }

    /// Status is derived, so no button sets one: Review Steps opens the steps where checking happens; Lean and
    /// computations run only when a person clicks Check or Run on exactly what will run.
    private var actions: some View {
        let statement = problem.statements?.first { $0.stableID == node.id }
        return VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8, lineSpacing: 6) {
                Button("Review Steps", action: onReview)
                    .disabled(node.sources.isEmpty)
                    .help(node.sources.isEmpty ? "\(node.label) has no source steps to review"
                                               : "Open the steps \(node.label) was promoted from in Review")
                Button("Formalize in Lean…") { verification?(.formalize(statement: node.id)) }
                    .help("Ask a formalizer for the Lean statement and proof of \(node.label)")
                if statement?.leanResult?.storedSource != nil {
                    Button("Check Again…") { verification?(.checkLean(statement: node.id, candidate: .current, editing: false)) }
                    Button("Confirm Statement…") { verification?(.confirmStatement(node.id)) }
                }
                Button("Ask for a Check…") {
                    verification?(.askForCheck(ScoutSeed(claim: node.statementLaTeX, statements: [node.id])))
                }
                .help("Ask a scout for a computation that tests \(node.label)")
                Button("Write a Computation…") { verification?(.writeCell(statement: node.id, basedOn: nil)) }
                if statement?.refutationAcceptedByID != nil {
                    Button("Withdraw Refutation") { verification?(.withdrawRefutation(statement: node.id)) }
                }
            }
            .disabled(verification == nil)
            Text(VerificationWording.inspectorCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8, lineSpacing: 6) {
                Button("Edit…", action: onEdit)
                Button("Delete…", role: .destructive, action: onDelete)
                    .disabled(node.isPinned)
                    .help(node.isPinned ? "The theorem goes only with its problem" : "Delete \(node.label)")
            }
        }
    }

    private func letter(_ author: Author?) -> String {
        if case .model(let slot) = author { return authors.letter(of: slot) }
        return authors.name(of: author)
    }

    private func add(_ dependency: UUID) {
        do {
            try graph?.addUse(dependency, to: node.id, in: problem)
            failure = nil
        } catch {
            failure = error.message
        }
    }

    private func remove(_ dependency: UUID) {
        graph?.removeUse(dependency, from: node.id, in: problem)
        failure = nil
    }
}

/// Another statement's label as a button that selects it.
private struct StatementLink: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .help("Select \(label)")
    }
}
