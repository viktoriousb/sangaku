import SwiftData
import SwiftUI

/// Presents the window's verification sheets and handles verification intents from every part of the window, the
/// inspector included: it is applied to the whole split view. While blind mode hides the models in Compare, no sheet
/// that names them is shown, whoever asked for it (invariant 9).
struct VerificationSheetHost: ViewModifier {
    let window: WindowState

    @Environment(\.leanService) private var lean
    @Environment(\.computeService) private var compute
    @Environment(\.citationService) private var citations
    @Environment(\.statementGraph) private var graph
    @Environment(\.problemManager) private var problems
    @State private var presenter = UUID()

    func body(content: Content) -> some View {
        let services = VerificationServices(lean: lean, compute: compute, citations: citations, graph: graph,
                                            problems: problems)
        content
            .environment(\.verificationActions, VerificationActions(presenter: presenter) { [window] intent in
                VerificationIntentHandler.perform(intent, window: window, services: services)
            })
            .sheet(item: Binding(get: { Self.presented(in: window) }, set: { window.verificationSheet = $0 })) { sheet in
                if let id = window.selectedProblemID {
                    ProblemScope(id: id) { problem in
                        VerificationSheetContent(sheet: sheet, problem: problem, window: window)
                    }
                }
            }
    }

    /// The sheet shown: the window's, unless it names models while blind mode hides them.
    static func presented(in window: WindowState) -> VerificationSheet? {
        window.verificationSheet.flatMap { $0.waitsWhileBlind && window.hidesModelChrome ? nil : $0 }
    }
}

/// One sheet, its subjects found by stable ID in the problem.
private struct VerificationSheetContent: View {
    let sheet: VerificationSheet
    let problem: Problem
    let window: WindowState

    @Environment(\.modelContext) private var context

    var body: some View {
        let branch = window.selectedBranch(in: problem)
        switch sheet {
        case .formalize(let id):
            if let statement = statement(id), let branch { FormalizeSheet(problem: problem, statement: statement, branch: branch) }
        case .leanCheck(let id, let candidate, let editing):
            if let statement = statement(id) {
                LeanCheckSheet(problem: problem, statement: statement, candidate: candidate, startsEditing: editing)
            }
        case .fidelity(let id):
            if let statement = statement(id) { FidelitySheet(problem: problem, statement: statement) }
        case .scout(let seed):
            if let branch { ScoutSheet(problem: problem, seed: seed, branch: branch) }
        case .cellEditor(let id, let basedOn):
            if let statement = statement(id), let branch {
                CellEditorSheet(problem: problem, statement: statement,
                                basedOn: basedOn.flatMap { context.first(Message.self, stableID: $0)?.computeCell },
                                branch: branch)
            }
        case .refutation(let id, let evidenceID):
            if let statement = statement(id), let evidence = (statement.evidence ?? []).first(where: { $0.stableID == evidenceID }) {
                RefutationSheet(problem: problem, statement: statement, evidence: evidence)
            }
        case .citationCheck(let attemptID):
            if let attempt = context.first(ProofAttempt.self, stableID: attemptID) { CitationCheckSheet(attempt: attempt) }
        case .citationAdd(let stepID):
            if let step = context.first(Step.self, stableID: stepID) { CitationAddSheet(step: step) }
        }
    }

    private func statement(_ id: UUID) -> Statement? {
        (problem.statements ?? []).first { $0.stableID == id }
    }
}

/// Why the last verification action was refused, above the workspace until dismissed.
struct VerificationNoticeBanner: View {
    let window: WindowState

    var body: some View {
        if let notice = window.verificationNotice {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                Text(notice).lineLimit(2)
                Spacer()
                Button("Dismiss") { window.verificationNotice = nil }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            // Entered as a group, so Dismiss stays its own control.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Notice")
        }
    }
}

extension View {
    /// The window's verification sheets and intents (`VerificationSheetHost`).
    func verificationSheets(window: WindowState) -> some View {
        modifier(VerificationSheetHost(window: window))
    }
}
