import Foundation

/// Something recorded at a time, ordered by that time and then by ID, so every reader agrees on the order of
/// records made at the same instant. `Step.latestRevision` uses the same order.
nonisolated protocol TimeOrdered {
    var id: UUID { get }
    var createdAt: Date { get }
}

nonisolated extension TimeOrdered {
    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
    }
}

/// One revision of a step as plain values.
nonisolated struct RevisionFact: Hashable, Sendable, Identifiable, TimeOrdered {
    var id: UUID
    var createdAt: Date
    var author: Author?
    var textLaTeX: String
    var establishes: String
}

/// One ✓, ✗ or ? as plain values, with its dismissal or withdrawal.
nonisolated struct ReviewFact: Hashable, Sendable, Identifiable, TimeOrdered {
    var id: UUID
    var createdAt: Date
    var reviewerID: UUID?
    var verdict: ReviewVerdict
    /// The revision it was given on.
    var revisionID: UUID?
    var note = ""
    var withdrawnAt: Date?
    var dismissedByID: UUID?
    var dismissalReason: String?
    var dismissedAt: Date?
}

/// One comment on a step.
nonisolated struct CommentFact: Hashable, Sendable, Identifiable, TimeOrdered {
    var id: UUID
    var createdAt: Date
    var author: Author?
    var body: String
    /// The revision its author was reading.
    var revisionID: UUID?
}

/// One step as plain values: its text, its revisions, reviews and comments.
nonisolated struct StepFact: Hashable, Sendable, Identifiable {
    var id: UUID
    var index: Int
    var confidence: Confidence
    /// `Step.textLaTeX` and `establishes`, which mirror the latest revision.
    var text: String
    var establishes: String
    /// Oldest first, in `RevisionFact.precedes` order.
    var revisions: [RevisionFact] = []
    /// Oldest first.
    var reviews: [ReviewFact] = []
    var comments: [CommentFact] = []

    var current: RevisionFact? { revisions.last }
}

/// One attempt as plain values: its steps by index and its referee verdicts.
nonisolated struct AttemptFact: Hashable, Sendable, Identifiable {
    var id: UUID
    var steps: [StepFact]
    var verdicts: [VerdictFact] = []
}
