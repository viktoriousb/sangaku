import SwiftData
import SwiftUI

/// Proof structure: the statement graph with derived statuses, the selected statement, and the legend.
struct InspectorPanel: View {
    let window: WindowState

    var body: some View {
        if window.hidesModelChrome {
            // The graph says which model each statement came from (invariant 9).
            ContentUnavailableView {
                Label("Hidden in blind mode", systemImage: "eye.slash")
            } description: {
                Text("The proof structure names who wrote each statement. It returns when blind mode is off (⌘⇧B).")
            }
        } else {
            ScrollView {
                InspectorContent(window: window)
            }
        }
    }
}

/// What the inspector shows. It fits the inspector's width (`WindowRoot.inspectorWidth`).
struct InspectorContent: View {
    let window: WindowState

    static let padding: CGFloat = 16
    /// The width the graph is laid out in: the inspector's width less this view's padding.
    static let contentWidth = WindowRoot.inspectorWidth - 2 * padding

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Proof structure").font(.headline)
                    Spacer()
                    caption
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proof structure").font(.headline)
                    caption
                }
            }
            // The inspector sits outside the workspace's problem scope, so it looks the problem up itself: that
            // also gives its math the problem's macros.
            if let id = window.selectedProblemID {
                ProblemScope(id: id) { problem in
                    ProofStructure(problem: problem, window: window)
                }
            } else {
                Text("Select a problem to see its statements.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Status").font(.subheadline.weight(.semibold))
            StatusLegend()
            MarkLegend()
        }
        .padding(Self.padding)
    }

    private var caption: some View {
        Text("arrow = “is used by”").font(.caption).foregroundStyle(.secondary)
    }
}

/// One problem's graph and the selected statement, with the editor and the delete confirmation.
private struct ProofStructure: View {
    let problem: Problem
    let window: WindowState

    @Environment(\.statementGraph) private var graph
    @Query private var people: [Person]
    @State private var editing: StatementNode?
    @State private var deleting: StatementNode?
    @State private var failure: String?

    var body: some View {
        if let graph {
            // Read on every render, never cached: a new verdict or review shows at once.
            let state = graph.state(for: problem, people: Set(people.map(\.stableID)))
            let selectedID = window.selectedNodeID
            let placement = GraphPlacement(state: state, metrics: .init(width: InspectorContent.contentWidth))
            VStack(alignment: .leading, spacing: 16) {
                StatementGraphView(state: state, placement: placement, selectedID: selectedID,
                                   onSelect: { window.selectedNodeID = $0 },
                                   onEdit: { editing = state[$0] },
                                   onDelete: { deleting = state[$0] })
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(ColorToken.refuted.color)
                }
                if let node = state[selectedID] {
                    let statement = (problem.statements ?? []).first { $0.stableID == node.id }
                    let personIDs = Set(people.map(\.stableID))
                    StatementDetail(node: node, state: state, problem: problem,
                                    authors: AuthorDirectory(problem: problem, people: people, catalog: .standard),
                                    lean: statement.map { LeanFacts.read($0, people: personIDs) },
                                    runs: statement.map { EvidenceFact.runs(of: $0, people: personIDs) } ?? [],
                                    onSelect: { window.selectedNodeID = $0 },
                                    onEdit: { editing = node },
                                    onDelete: { deleting = node },
                                    onReview: { window.openReview(statement: node, in: problem) })
                } else {
                    Text("Select a statement to see what it uses and what holds its status down.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(item: $editing) { node in
                StatementEditor(problem: problem, node: node)
            }
            .confirmationDialog("Delete \(deleting?.label ?? "the statement")?", isPresented: isDeleting,
                                presenting: deleting) { node in
                Button("Delete \(node.label)", role: .destructive) { delete(node) }
            } message: { node in
                Text(state.deletionNote(for: node.id))
            }
        } else {
            Text("Proof structure is unavailable in this window.")
                .foregroundStyle(.secondary)
        }
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func delete(_ node: StatementNode) {
        guard let graph else { return }
        do {
            try window.delete(statement: node.id, in: problem, using: graph)
            failure = nil
        } catch {
            failure = error.message
        }
    }

}

/// The marks a statement can carry besides its status.
private struct MarkLegend: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(StatusMark.allCases, id: \.self) { mark in
                GridRow {
                    Text(verbatim: mark.glyph).frame(width: 22)
                    Text(mark.legend).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(mark.legend))
            }
        }
        .font(.caption)
    }
}

#if DEBUG
#Preview("Inspector", traits: .fixture, .fixedLayout(width: 340, height: 1100)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @State var window = WindowState()
    InspectorPanel(window: window)
        .onAppear {
            window.select(problem: problems.first)
            window.selectedNodeID = problems.first?.statements?.first { $0.label == "Lem 5" }?.stableID
        }
}
#endif
