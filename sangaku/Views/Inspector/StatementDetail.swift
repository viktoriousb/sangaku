import SwiftUI

/// The selected statement: what it says, its displayed status and what holds it down, what it uses and is used
/// by (as buttons that select them), its delicate steps and who wrote it.
struct StatementDetail: View {
    let node: StatementNode
    let state: StatementGraphState
    let problem: Problem
    let authors: AuthorDirectory
    let onSelect: (UUID) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    /// Opens Review on the statement's source steps.
    let onReview: () -> Void

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
            let candidates = state.candidates(toUse: node.id)
            if !candidates.isEmpty {
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

    /// Status is derived, so no button sets one: Review Steps opens the steps where checking happens. Lean names the
    /// milestone that brings it, in words a keyboard user sees too (a disabled button takes no focus).
    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8, lineSpacing: 6) {
                Button("Review Steps", action: onReview)
                    .disabled(node.sources.isEmpty)
                    .help(node.sources.isEmpty ? "\(node.label) has no source steps to review"
                                               : "Open the steps \(node.label) was promoted from in Review")
                Button("Formalize in Lean") {}
                    .disabled(true)
                    .help("Lean arrives with Milestone 8 (Verification)")
            }
            Text("Review Steps opens the source steps; checking happens there. No button sets a status. Lean arrives with Milestone 8.")
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
