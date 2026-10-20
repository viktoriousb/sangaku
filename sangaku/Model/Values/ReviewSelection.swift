import Foundation

/// Where "Review" was asked to open: the attempts of a referee message, or one attempt and step.
nonisolated struct ReviewTarget: Hashable, Sendable {
    var attemptIDs: [UUID]
    var stepID: UUID?
}

/// Which attempt one window's Review shows. Everything else is derived on each render. The current step is kept
/// apart (`WindowState.reviewStepID`), so moving between steps does not choose the attempt again.
nonisolated struct ReviewSelection: Hashable, Sendable {
    /// An attempt picked by hand; nil means "choose by the rule in `ReviewAttemptChoice`".
    var attemptID: UUID?
    /// The attempts of the referee message Review was opened from, in order.
    var candidateAttemptIDs: [UUID] = []
    /// The statement whose source steps Review was opened for ("Review Steps" in the inspector).
    var highlightedStatementID: UUID?
}

/// Keyboard focus in Review: the step list (where J, K, 1, 2, 3 and C act) or a text field of one step.
nonisolated enum ReviewFocus: Hashable, Sendable {
    case list
    case field(UUID)
}

nonisolated enum ReviewAttemptChoice {
    /// The attempt picked by hand if it is still offered; else one of the referee message's attempts (the first the
    /// referee found complete, else the first); else the theorem's source attempt; else the newest refereed attempt;
    /// else the newest.
    static func resolve(_ selection: ReviewSelection, among options: [AttemptOption],
                        theoremSourceAttemptID: UUID?) -> UUID? {
        let offered = Set(options.map(\.id))
        if let picked = selection.attemptID, offered.contains(picked) { return picked }
        let candidates = selection.candidateAttemptIDs.compactMap { id in options.first { $0.id == id } }
        if let candidate = candidates.first(where: { $0.standingOutcome == .complete }) ?? candidates.first {
            return candidate.id
        }
        if let theoremSourceAttemptID, offered.contains(theoremSourceAttemptID) { return theoremSourceAttemptID }
        let newestFirst = options.sorted { AttemptOption.precedes($1, $0) }
        return (newestFirst.first { $0.standingOutcome != nil } ?? newestFirst.first)?.id
    }
}
