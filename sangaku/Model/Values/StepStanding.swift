import Foundation

/// Where a step stands with people.
nonisolated enum HumanStanding: Hashable, Sendable {
    case unchecked, checked, objected
}

/// Rule 4 for one step: whether the standing referee verdict vouches for the step's current text, and if not, why.
nonisolated enum ModelCheck: Hashable, Sendable {
    case noVerdict
    /// The standing verdict lists this step as a gap.
    case gapListed(referee: UUID?)
    /// The standing verdict found a gap elsewhere in the attempt, so it vouches for nothing.
    case attemptHasGap(referee: UUID?)
    /// The verdict is "complete", but the step was revised after the referee's request: it judged earlier text.
    case revisedSince(referee: UUID?)
    /// The verdict records no request time, so what it saw is unknown. It vouches for nothing.
    case unknownBasis(referee: UUID?)
    case complete(referee: UUID?)

    var passes: Bool {
        if case .complete = self { true } else { false }
    }

    var referee: UUID? {
        switch self {
        case .noVerdict: nil
        case .gapListed(let referee), .attemptHasGap(let referee), .revisedSince(let referee),
             .unknownBasis(let referee), .complete(let referee): referee
        }
    }
}

/// "Re-check: an earlier step changed": an earlier step changed what it establishes after this step's latest ✓.
nonisolated struct Recheck: Hashable, Sendable {
    nonisolated struct Cause: Hashable, Sendable {
        var stepIndex: Int
        var revisionID: UUID
        var at: Date
    }

    var causes: [Cause]

    var stepIndices: [Int] { Array(Set(causes.map(\.stepIndex))).sorted() }
}

/// One step's standing, derived from its reviews and the referee's verdict. The single per-step rule: statement
/// status (rules 3 and 4), the Review screen's chips, the progress count and the rotors all read it.
nonisolated struct StepStanding: Hashable, Sendable, Identifiable {
    var id: UUID
    var index: Int
    var currentRevisionID: UUID?
    var currentRevisionAt: Date?
    /// A person's ✓ on the current revision, not withdrawn. Newest first.
    var checks: [ReviewFact] = []
    /// ✓ on the current revision that their reviewer withdrew.
    var withdrawnChecks: [ReviewFact] = []
    /// ✗ or ? on the current revision that no person dismissed with a reason (invariant 11). Newest first.
    var openObjections: [ReviewFact] = []
    /// ✗ or ? on the current revision that a person dismissed with a reason.
    var dismissedObjections: [ReviewFact] = []
    /// ✗ or ? on the current revision that the person who raised it withdrew.
    var withdrawnObjections: [ReviewFact] = []
    /// A ✓ on the current revision from someone who is not a person: it counts for nothing (invariant 1).
    var uncounted: [ReviewFact] = []
    /// Anything given on an earlier revision: kept for history, never counted (invariant 2).
    var staleReviews: [ReviewFact] = []
    var model: ModelCheck = .noVerdict
    /// Earlier steps changed what they establish after the latest ✓ on the current revision, whether or not that ✓
    /// counts now. Repeating a ✓ reads it; the flag shows only once the ✓ counts (`recheck`).
    var changedSinceCheck: Recheck?

    var human: HumanStanding {
        !openObjections.isEmpty ? .objected : !checks.isEmpty ? .checked : .unchecked
    }

    /// A person's ✓ on the current revision and no open objection. A re-check flag does not change it.
    var countsAsChecked: Bool { human == .checked }

    /// "Re-check: an earlier step changed": shown on a step that counts as checked.
    var recheck: Recheck? { countsAsChecked ? changedSinceCheck : nil }

    var latestCheckAt: Date? { checks.map(\.createdAt).max() }
}

nonisolated enum StepStandings {
    /// Every step of an attempt, in index order.
    static func derive(_ attempt: AttemptFact, people: Set<UUID>) -> [StepStanding] {
        let standing = StatusRules.standingVerdict(attempt.verdicts)
        let steps = attempt.steps.sorted { $0.index < $1.index }
        var standings = steps.map { step in
            var result = human(step, people: people)
            result.model = StatusRules.modelCheck(standing, stepIndex: step.index,
                                                  latestRevisionAt: step.current?.createdAt)
            return result
        }

        // Re-check: an earlier step changed what it establishes after this step's latest ✓.
        var changes: [Recheck.Cause] = []
        for step in steps {
            for (previous, revision) in zip(step.revisions, step.revisions.dropFirst())
            where normalized(previous.establishes) != normalized(revision.establishes) {
                changes.append(Recheck.Cause(stepIndex: step.index, revisionID: revision.id, at: revision.createdAt))
            }
        }
        for position in standings.indices {
            guard let lastCheck = standings[position].latestCheckAt else { continue }
            let index = standings[position].index
            // In doubt (equal times), flag: a flag never changes a status.
            let causes = changes.filter { $0.stepIndex < index && $0.at >= lastCheck }
            if !causes.isEmpty { standings[position].changedSinceCheck = Recheck(causes: causes) }
        }
        return standings
    }

    /// A dismissal counts only from a person, with a reason.
    static func isValidDismissal(_ review: ReviewFact, people: Set<UUID>) -> Bool {
        review.dismissedByID.map(people.contains) == true
            && !(review.dismissalReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func human(_ step: StepFact, people: Set<UUID>) -> StepStanding {
        let current = step.current
        var result = StepStanding(id: step.id, index: step.index, currentRevisionID: current?.id,
                                  currentRevisionAt: current?.createdAt)
        for review in step.reviews {
            // A step with no current revision has nothing a review could be on: it counts nothing (fails closed).
            guard let current, review.revisionID == current.id else {
                result.staleReviews.append(review)
                continue
            }
            if review.verdict == .correct {
                if !(review.reviewerID.map(people.contains) ?? false) {
                    result.uncounted.append(review)
                } else if review.withdrawnAt != nil {
                    result.withdrawnChecks.append(review)
                } else {
                    result.checks.append(review)
                }
            } else if isValidDismissal(review, people: people) {
                result.dismissedObjections.append(review)
            } else if review.withdrawnAt != nil, review.reviewerID.map(people.contains) == true {
                // Withdrawn by the person who raised it (only they can withdraw it).
                result.withdrawnObjections.append(review)
            } else {
                // A ✗ or ? blocks whoever raised it, even a reviewer whose record is gone. A withdrawal counts only
                // from a person, so one that cannot be traced to a person leaves the objection open (fails closed).
                result.openObjections.append(review)
            }
        }
        result.checks.sort(by: newestFirst)
        result.openObjections.sort(by: newestFirst)
        result.withdrawnChecks.sort(by: newestFirst)
        result.dismissedObjections.sort(by: newestFirst)
        result.withdrawnObjections.sort(by: newestFirst)
        return result
    }

    private static func newestFirst(_ lhs: ReviewFact, _ rhs: ReviewFact) -> Bool {
        ReviewFact.precedes(rhs, lhs)
    }

    static func normalized(_ establishes: String) -> String {
        establishes.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
