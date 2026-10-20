import Foundation

/// An attempt Review and Compare can show: finished or partial, with steps.
nonisolated struct AttemptOption: Hashable, Sendable, Identifiable, TimeOrdered {
    var id: UUID
    var createdAt: Date
    var author: Author?
    var stepCount: Int
    /// Stopped, cut off or failed: shown, and marked partial.
    var isPartial: Bool
    var standingOutcome: RefereeOutcome?
    /// The fan-out the attempt belongs to.
    var fanOutID: UUID? = nil
}

extension AttemptOption {
    /// The attempts on a branch that have steps to review: finished or partial, never streaming or declined.
    static func make(messages: [Message], live: Set<UUID>) -> [AttemptOption] {
        messages.compactMap { message in
            guard message.kind == .attempt, !live.contains(message.stableID),
                  let attempt = message.proofAttempt, !(attempt.steps ?? []).isEmpty else { return nil }
            let outcome = message.outcome(isStreaming: false)
            if case .declined = outcome { return nil }
            return AttemptOption(id: attempt.stableID, createdAt: message.createdAt, author: message.author,
                                       stepCount: attempt.steps?.count ?? 0, isPartial: outcome.isPartial,
                                       standingOutcome: attempt.standingVerdict?.outcome, fanOutID: attempt.fanOut?.stableID)
        }
        .sorted(by: AttemptOption.precedes)
    }
}
