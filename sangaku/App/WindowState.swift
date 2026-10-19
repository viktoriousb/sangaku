import SwiftUI

/// The four workspace views, switched with ⌘1–⌘4.
nonisolated enum WorkspaceView: String, CaseIterable, Identifiable, Hashable, Sendable {
    case thread, compare, review, branches

    var id: Self { self }

    var title: String {
        switch self {
        case .thread: "Thread"
        case .compare: "Compare"
        case .review: "Review"
        case .branches: "Branches"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .thread: "1"
        case .compare: "2"
        case .review: "3"
        case .branches: "4"
        }
    }
}

/// What one window shows. Created as `@State` in `WindowRoot`; every property is `Equatable`, so assigning an
/// unchanged value does not invalidate views.
@Observable
final class WindowState {
    var selectedProblemID: UUID?
    var selectedBranchID: UUID?
    var activeView: WorkspaceView = .thread
    var inspectorPresented = true
    var selectedNodeID: UUID?
    var blindMode = false
    /// The problem editor sheet is open (set when a new problem is created).
    var isEditingProblem = false
    var review = ReviewSelection()
    /// Review's current step: drawn with its own ring, and what the keys and the Review menu act on.
    var reviewStepID: UUID?

    /// Selecting a problem resets the branch to its main line.
    func select(problem: Problem?) {
        selectedProblemID = problem?.stableID
        selectedBranchID = problem?.mainBranchID
        selectedNodeID = nil
        review = ReviewSelection()
        reviewStepID = nil
    }

    /// The branch shown: the one selected, else the problem's main line.
    func selectedBranch(in problem: Problem) -> Branch? {
        let id = selectedBranchID ?? problem.mainBranchID
        return problem.sortedBranches.first { $0.stableID == id }
    }

    /// Creates a problem, shows it in the thread and opens its editor. The one path for New Problem.
    func createProblem(using problems: ProblemManager) {
        select(problem: problems.createProblem())
        activeView = .thread
        isEditingProblem = true
    }

    /// Opens the editor for a problem.
    func edit(_ problem: Problem) {
        if selectedProblemID != problem.stableID { select(problem: problem) }
        isEditingProblem = true
    }

    /// Shows a statement in the proof-structure inspector.
    func reveal(statement id: UUID) {
        selectedNodeID = id
        inspectorPresented = true
    }

    /// Opens Review on a referee message's attempts, or on one attempt at a step.
    func openReview(_ target: ReviewTarget) {
        review = ReviewSelection(candidateAttemptIDs: target.attemptIDs)
        reviewStepID = target.stepID
        activeView = .review
    }

    /// Opens Review on a statement's source steps: the attempt of the first, at that step, with the statement's
    /// steps marked.
    func openReview(statement node: StatementNode) {
        guard let first = node.sources.first else { return }
        review = ReviewSelection(candidateAttemptIDs: first.attemptID.map { [$0] } ?? [], highlightedStatementID: node.id)
        reviewStepID = first.stepID
        activeView = .review
    }

    /// Picks an attempt by hand; the current step starts over.
    func chooseReview(attempt id: UUID) {
        guard review.attemptID != id else { return }
        review.attemptID = id
        review.highlightedStatementID = nil
        reviewStepID = nil
    }

    func focusReview(step id: UUID?) {
        if reviewStepID != id { reviewStepID = id }
    }

    func clearReviewHighlight() {
        review.highlightedStatementID = nil
    }

    /// Deletes a statement, clearing the inspector's selection if it was the one selected.
    func delete(statement id: UUID, in problem: Problem, using graph: StatementGraph) throws(StatementError) {
        try graph.delete(id, in: problem)
        if selectedNodeID == id { selectedNodeID = nil }
    }

    /// Deletes a problem, clearing the selection first if this window shows it.
    func delete(_ problem: Problem, using problems: ProblemManager) {
        if selectedProblemID == problem.stableID { select(problem: nil) }
        problems.delete(problem)
    }
}
