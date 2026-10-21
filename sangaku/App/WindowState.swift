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
    var compare = CompareSelection()
    /// Compare's current row.
    var compareRow: RowKey?
    /// All rows or differences only. Kept across comparisons, and apart from them, so filtering re-derives nothing.
    var compareFilter: CompareFilter = .all
    /// The Branches screen's selected node (a branch, attempt or lemma by stable ID): it fills that screen's panel
    /// only, and never changes the branch the window shows.
    var branchesSelection: UUID?
    /// Whether the Branches screen shows dead ends. Kept across problems, like `compareFilter`.
    var showsDeadEnds = true
    /// The branch sheet open in this window, from whichever screen asked for it (`BranchSheetHost`).
    var branchSheet: BranchSheet?
    /// The verification sheet open in this window (`VerificationSheetHost`).
    var verificationSheet: VerificationSheet?
    /// Why the last verification action was refused, until the next one succeeds or it is dismissed.
    var verificationNotice: String?

    /// While blind mode is on in Compare, the toolbar's model chips and the proof-structure inspector are hidden:
    /// both name the models (invariant 9). Kept hidden after a verdict reveals one comparison, failing closed, until
    /// blind mode is turned off.
    var hidesModelChrome: Bool { blindMode && activeView == .compare }

    /// Selecting a problem resets the branch to its main line.
    func select(problem: Problem?) {
        selectedProblemID = problem?.stableID
        selectedBranchID = problem?.mainBranchID
        selectedNodeID = nil
        resetSelections()
        branchesSelection = nil
        branchSheet = nil
        verificationSheet = nil
        verificationNotice = nil
    }

    /// Review's and Compare's selections start over: they name attempts of the problem and branch shown.
    private func resetSelections() {
        review = ReviewSelection()
        reviewStepID = nil
        compare = CompareSelection()
        compareRow = nil
    }

    /// The branch shown: the one selected, else the problem's main line. A selection that names no branch any more
    /// falls back to the main line.
    func selectedBranch(in problem: Problem) -> Branch? {
        let id = selectedBranchID ?? problem.mainBranchID
        return problem.sortedBranches.first { $0.stableID == id } ?? problem.mainBranch
    }

    /// Shows another branch in Thread, Review and Compare. Their selections start over, as for a new problem.
    func switchBranch(to id: UUID) {
        guard selectedBranchID != id else { return }
        selectedBranchID = id
        resetSelections()
    }

    /// Shows a branch's messages in the thread.
    func openMessages(of id: UUID) {
        switchBranch(to: id)
        activeView = .thread
    }

    /// Shows a branch, attempt or lemma on the Branches screen.
    func showInBranches(_ id: UUID) {
        branchesSelection = id
        activeView = .branches
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
    /// steps marked. When the branch shown does not hold that attempt, the window shows the branch it was written on.
    func openReview(statement node: StatementNode, in problem: Problem) {
        guard let first = node.sources.first else { return }
        if let attemptID = first.attemptID, let branchID = first.branchID,
           selectedBranch(in: problem)?.visibleHistory.all.contains(where: { $0.proofAttempt?.stableID == attemptID }) != true {
            switchBranch(to: branchID)
        }
        review = ReviewSelection(candidateAttemptIDs: first.attemptID.map { [$0] } ?? [], highlightedStatementID: node.id)
        reviewStepID = first.stepID
        activeView = .review
    }

    /// Opens Compare on a fan-out's or referee message's attempts.
    func openCompare(_ target: CompareTarget) {
        compare = CompareSelection(candidateAttemptIDs: target.attemptIDs)
        compareRow = nil
        activeView = .compare
    }

    /// Picks the two attempts by hand; the current row starts over.
    func chooseCompare(_ attemptIDs: [UUID]) {
        guard compare.picked != attemptIDs else { return }
        compare.picked = attemptIDs
        compareRow = nil
    }

    func focusCompare(row key: RowKey?) {
        if compareRow != key { compareRow = key }
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
