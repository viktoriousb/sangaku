import Foundation

/// Why a verification action was refused. Every refusal is decided before anything is written or run.
nonisolated enum VerificationError: Error, Hashable, Sendable {
    case noSuchStatement
    case noSuchDraft
    case noSuchCell
    case noSuchEvidence
    case noSuchCitation
    /// The Lean workspace is not ready; the words say why.
    case workspace(String)
    case checkRunning
    case cellRunning
    case lookupRunning
    case fetchRunning
    case gate(LeanGate.Refusal)
    /// Another statement's stored Lean code no longer passes the gate.
    case storedCodeRefused(label: String, LeanGate.Refusal)
    /// A statement's Lean code names another statement's code where it may not (`LeanService.checkReferences`).
    case namesOtherStatement(label: String, named: String, inStatementPart: Bool)
    case changedSinceShown
    case noLeanResult
    case noFidelityToWithdraw
    case toolNotSetUp(ToolID)
    case toolNotUsable(ToolID, String)
    case noStatementAttached
    case notACounterexample
    case noteRequired
    case alreadyRefuted
    case notRefuted
    /// Text a person entered cannot be used; the words say why.
    case invalid(String)
    case nothingToCheck

    var message: String {
        switch self {
        case .noSuchStatement: "That statement is no longer in the problem."
        case .noSuchDraft: "That Lean draft is no longer available."
        case .noSuchCell: "That computation is no longer available."
        case .noSuchEvidence: "That run is no longer recorded."
        case .noSuchCitation: "That citation is no longer on its step."
        case .workspace(let reason): reason
        case .checkRunning: "A Lean check of this problem is already running."
        case .cellRunning: "This computation is already running."
        case .lookupRunning: "Citations are already being looked up."
        case .fetchRunning: "Mathlib is already being fetched."
        case .gate(let refusal): refusal.message
        case .storedCodeRefused(let label, let refusal): "The checked Lean code of \(label) is refused: \(refusal.message)"
        case .namesOtherStatement(let label, let named, true):
            "The Lean statement of \(label) names the code of \(named). A statement part may use Mathlib and its own definitions only, so that what it says is all in what is compared with the informal statement."
        case .namesOtherStatement(let label, let named, false):
            "The Lean proof of \(label) names \(named), which \(label) does not use. Add \(named) to what \(label) uses first, so that its status is capped by it."
        case .changedSinceShown: "What would run changed after it was shown. Look at it again before running it."
        case .noLeanResult: "There is no checked Lean statement to compare yet."
        case .noFidelityToWithdraw: "You have given no review of this Lean statement to withdraw."
        case .toolNotSetUp(let tool): "\(tool.displayName) is not set up. Set its path in Settings."
        case .toolNotUsable(let tool, let reason): "\(tool.displayName) cannot be used: \(reason)"
        case .noStatementAttached: "The computation is not attached to a statement in this problem."
        case .notACounterexample: "Only a run whose code reported a counterexample can refute a statement."
        case .noteRequired: "Say in your own words why the statement is refuted."
        case .alreadyRefuted: "The statement is already refuted."
        case .notRefuted: "The statement is not refuted by a person."
        case .invalid(let reason): reason
        case .nothingToCheck: "There is nothing to check."
        }
    }
}
