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
    case pinnedCannotBeImported
    case importedHasSteps
    case invalidImportedSource
    /// A statement that uses others cannot be marked imported, and an imported one uses none: so it can never hide a
    /// refuted claim from what rests on it.
    case importedUsesStatements
    case importedCannotUse

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
        case .pinnedCannotBeImported:
            "The problem's theorem is what is being proved here; it cannot be marked as imported."
        case .importedHasSteps:
            "This statement rests on steps written here, so it is proved here, not imported."
        case .invalidImportedSource:
            "Give the source on one line of at most 200 characters, such as \"Dummit and Foote, Theorem 4.5.18\"."
        case .importedUsesStatements:
            "A result from the literature rests on nothing proved here. Remove what this statement uses, then mark it imported."
        case .importedCannotUse:
            "An imported result has no proof here, so it uses no other statement."
        }
    }
}
