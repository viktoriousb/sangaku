import Foundation

/// Why a change to branches or the adopted proof was refused. Every refusal leaves the store unchanged.
nonisolated enum BranchError: Error, Hashable, Sendable {
    case emptyName
    case duplicateName(String)
    case noSuchBranch
    case noSuchMessage
    /// A branch with no message yet has nothing to fork from.
    case noMessageToForkFrom
    /// The sheet would name who wrote what while blind mode hides it in Compare (invariant 9).
    case blind
    /// The fork chain cannot be read (`BranchHistory.Fault`).
    case historyUnreadable(BranchHistory.Fault)
    /// The message to fork from, or one before it, is still being written.
    case messageStillRunning
    /// A request is running on the branch.
    case branchBusy
    case isMainLine
    /// A dead end in context with no text would tell every model "(no reason recorded)".
    case reasonRequired
    /// Only a dead end or parked branch has reasons to edit.
    case notClosed
    /// Only a dead end is ever sent to models.
    case notADeadEnd
    /// A text was started from a message this branch does not show.
    case messageNotOnBranch
    case noSuchAttempt
    case attemptHasNoSteps
    case attemptStillRunning
    /// The attempt's branch is a dead end or parked.
    case branchClosed(BranchState)
    case alreadyAdopted
    /// What is known about the attempt changed since its warnings were shown.
    case warningsNotAcknowledged
    case nothingToCherryPick
    case statement(StatementError)

    var message: String {
        switch self {
        case .emptyName: "Give the branch a name."
        case .duplicateName(let name): "A branch is already called \u{201C}\(name)\u{201D}. Choose another name."
        case .noSuchBranch: "That branch is no longer in this problem."
        case .noSuchMessage: "That message is no longer in this problem."
        case .noMessageToForkFrom: "This branch has no message to fork from yet."
        case .blind:
            "Blind mode hides who wrote each attempt, and this would show it. Leave Compare or turn blind mode off first."
        case .historyUnreadable(let fault): fault.message + " Nothing was changed."
        case .messageStillRunning:
            "That message, or one before it, is still being written. Stop it or wait until it ends; you can fork from an earlier message now."
        case .branchBusy: "Something is still running on this branch. Stop it first."
        case .isMainLine: "The main line can't be a dead end or parked. Adopt an attempt on another branch first."
        case .reasonRequired:
            "Write why it died before it is sent to models: they would be told \u{201C}\(BranchReasons.noReason)\u{201D}."
        case .notClosed: "Only a dead end or parked branch has reasons to edit."
        case .notADeadEnd: "Only a dead end is sent to models. A parked branch never is."
        case .messageNotOnBranch: "That message is not part of this branch's history."
        case .noSuchAttempt: "That attempt is no longer in this problem."
        case .attemptHasNoSteps: "This attempt was not read as steps, so there is no proof to adopt."
        case .attemptStillRunning: "This attempt is still being written. Stop it or wait until it ends."
        case .branchClosed(let state): "This attempt is on a branch that is \(state.phrase). Reopen it first."
        case .alreadyAdopted: "This attempt is already the proof of the main line."
        case .warningsNotAcknowledged: "What is known about this attempt changed. Read the warnings and confirm again."
        case .nothingToCherryPick: "This branch has no attempt read as steps to take a step from."
        case .statement(let error): error.message
        }
    }
}
