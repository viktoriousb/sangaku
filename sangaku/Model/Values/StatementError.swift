import Foundation

/// Why a change to the statements was refused. Every refusal leaves the store unchanged.
nonisolated enum StatementError: Error, Hashable, Sendable {
    case emptyLabel
    case duplicateLabel(String)
    case emptyStatement
    /// The labels along the cycle the change would close, starting and ending with the same statement.
    case cycle(labels: [String])
    case notInThisProblem
    case noSuchStatement
    case kindNotPromotable(StatementKind)
    case noSuchSteps
    case pinnedTheoremCannotBeDeleted
    case pinnedTextIsTheProblemStatement
    case textLockedByLeanCheck

    var message: String {
        switch self {
        case .emptyLabel:
            "Give the statement a label, such as Lem 5."
        case .duplicateLabel(let label):
            "\(label) is already a label in this problem. Choose another."
        case .emptyStatement:
            "Write the statement."
        case .cycle(let labels):
            "That would make \(labels.first ?? "a statement") depend on itself: \(labels.joined(separator: " → "))."
        case .notInThisProblem:
            "That statement or step belongs to another problem."
        case .noSuchStatement:
            "That statement is no longer in this problem."
        case .kindNotPromotable(let kind):
            "Steps become a lemma or a claim, not a \(kind.word.lowercased())."
        case .noSuchSteps:
            "Those steps are no longer in this problem."
        case .pinnedTheoremCannotBeDeleted:
            "The problem's theorem cannot be deleted. Delete the problem instead."
        case .pinnedTextIsTheProblemStatement:
            "The theorem's text is the problem statement. Edit the problem to change it."
        case .textLockedByLeanCheck:
            "A Lean result or fidelity review was given for this wording, so the text can no longer change. Promote a new statement instead."
        }
    }
}
