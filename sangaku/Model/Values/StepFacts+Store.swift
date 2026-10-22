import Foundation

// Reading steps and attempts out of the store as plain values. Called inside view bodies, so Observation tracks
// every property read here.

extension Step {
    var fact: StepFact {
        StepFact(
            id: stableID, index: index, confidence: confidence, text: textLaTeX, establishes: establishes,
            revisions: (revisions ?? []).map { RevisionFact($0) }.sorted(by: RevisionFact.precedes),
            reviews: (reviews ?? []).map {
                ReviewFact(id: $0.stableID, createdAt: $0.createdAt, reviewerID: $0.reviewerID, verdict: $0.verdict,
                           revisionID: $0.revisionReviewedID, note: $0.comments, withdrawnAt: $0.withdrawnAt,
                           dismissedByID: $0.dismissedByID, dismissalReason: $0.dismissalReason,
                           dismissedAt: $0.dismissedAt)
            }.sorted(by: ReviewFact.precedes),
            comments: (comments ?? []).map {
                CommentFact(id: $0.stableID, createdAt: $0.createdAt, author: $0.author, body: $0.body,
                            revisionID: $0.revisionID)
            }.sorted(by: CommentFact.precedes))
    }
}

nonisolated extension RevisionFact {
    init(_ revision: StepRevision) {
        self.init(id: revision.stableID, createdAt: revision.createdAt, author: revision.author,
                  textLaTeX: revision.textLaTeX, establishes: revision.establishes)
    }
}

extension ProofAttempt {
    var fact: AttemptFact {
        AttemptFact(id: stableID, steps: sortedSteps.map(\.fact), verdicts: verdictFacts)
    }
}

extension StepStandings {
    /// The standing of each of `steps`, by step ID. Each attempt is derived whole (re-check flags look at earlier
    /// steps); a step with no attempt is derived alone, with no verdict.
    static func standings(of steps: [Step], people: Set<UUID>) -> [UUID: StepStanding] {
        var result: [UUID: StepStanding] = [:]
        var attempts: [UUID: ProofAttempt] = [:]
        for step in steps {
            if let attempt = step.attempt {
                attempts[attempt.stableID] = attempt
            } else {
                let alone = AttemptFact(id: step.stableID, steps: [step.fact])
                for standing in derive(alone, people: people) { result[standing.id] = standing }
            }
        }
        for attempt in attempts.values {
            for standing in derive(attempt.fact, people: people) { result[standing.id] = standing }
        }
        return result
    }
}

extension AttemptReviewState {
    /// The attempt as the Review screen shows it, read fresh on every render.
    static func read(attempt: ProofAttempt, people: Set<UUID>) -> AttemptReviewState {
        AttemptReviewState(attempt.fact, people: people,
                           partial: attempt.message?.outcome(isStreaming: false).isPartial ?? false)
    }
}
