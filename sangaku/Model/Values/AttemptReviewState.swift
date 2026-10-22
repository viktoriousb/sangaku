import Foundation

/// One step as the Review screen shows it.
nonisolated struct StepReview: Hashable, Sendable, Identifiable {
    var id: UUID
    var index: Int
    var text: String
    var establishes: String
    var confidence: Confidence
    var standing: StepStanding
    var provenance: StepProvenance
    /// Oldest first.
    var comments: [CommentFact]
    /// Every review ever given on the step, oldest first, for its history.
    var reviews: [ReviewFact]

    /// The step's history, newest first: versions, reviews, dismissals, withdrawals and comments.
    var history: [HistoryEntry] {
        var entries: [HistoryEntry] = provenance.versions.map { .init(date: $0.createdAt, kind: .version($0)) }
        for review in reviews {
            entries.append(.init(date: review.createdAt, kind: .review(review)))
            if let at = review.dismissedAt { entries.append(.init(date: at, kind: .dismissal(review))) }
            if let at = review.withdrawnAt { entries.append(.init(date: at, kind: .withdrawal(review))) }
        }
        entries += comments.map { .init(date: $0.createdAt, kind: .comment($0)) }
        return entries.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// The version a review or comment was given on, as "version 2", when it is not the current one.
    func versionLabel(of revisionID: UUID?) -> String? {
        guard let revisionID, revisionID != standing.currentRevisionID,
              let version = provenance.versions.first(where: { $0.id == revisionID }) else { return nil }
        return "version \(version.number)"
    }
}

/// One event in a step's history.
nonisolated struct HistoryEntry: Hashable, Sendable, Identifiable {
    nonisolated enum Kind: Hashable, Sendable {
        case version(StepProvenance.Version)
        case review(ReviewFact)
        case dismissal(ReviewFact)
        case withdrawal(ReviewFact)
        case comment(CommentFact)
    }

    var date: Date
    var kind: Kind

    var id: String {
        switch kind {
        case .version(let version): "version-\(version.id)"
        case .review(let review): "review-\(review.id)"
        case .dismissal(let review): "dismissal-\(review.id)"
        case .withdrawal(let review): "withdrawal-\(review.id)"
        case .comment(let comment): "comment-\(comment.id)"
        }
    }
}

/// An attempt as the Review screen shows it: its steps with their standings, and the progress over them.
nonisolated struct AttemptReviewState: Hashable, Sendable {
    var attemptID: UUID
    /// In index order.
    var steps: [StepReview]
    var progress: ReviewProgress

    /// `partial`: the attempt stopped before its end.
    init(_ attempt: AttemptFact, people: Set<UUID>, partial: Bool = false) {
        let standings = Dictionary(StepStandings.derive(attempt, people: people).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        attemptID = attempt.id
        steps = attempt.steps.sorted { $0.index < $1.index }.compactMap { step in
            guard let standing = standings[step.id] else { return nil }
            return StepReview(id: step.id, index: step.index, text: step.currentText,
                              establishes: step.currentEstablishes, confidence: step.confidence,
                              standing: standing, provenance: StepProvenance(revisions: step.revisions),
                              comments: step.comments, reviews: step.reviews)
        }
        progress = ReviewProgress(steps.map(\.standing), partial: partial)
    }

    subscript(step id: UUID?) -> StepReview? { steps.first { $0.id == id } }

    /// Rotor "Unchecked steps": every step not counted as checked, blocked ones included.
    var uncheckedStepIDs: [UUID] { steps.filter { !$0.standing.countsAsChecked }.map(\.id) }

    /// Rotor "Delicate steps": navigation only; confidence never changes a review (invariant 10).
    var delicateStepIDs: [UUID] { steps.filter { $0.confidence == .delicate }.map(\.id) }
}
