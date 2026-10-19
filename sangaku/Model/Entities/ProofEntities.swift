import Foundation
import SwiftData

extension SangakuSchemaV1 {
    /// A model's structured proof attempt. `parsedCleanly` is false when the output had to be kept as raw text.
    @Model final class ProofAttempt {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var parsedCleanly: Bool = false
        var message: Message?
        var fanOut: FanOut?

        @Relationship(deleteRule: .cascade, inverse: \Step.attempt)
        var steps: [Step]? = []
        var verdicts: [RefereeVerdict]? = []

        init(parsedCleanly: Bool = false) {
            self.parsedCleanly = parsedCleanly
        }

        var sortedSteps: [Step] {
            (steps ?? []).sorted { $0.index < $1.index }
        }
    }

    /// One numbered proof step. `textLaTeX` and `establishes` mirror the latest revision; the history and its
    /// authors live in `revisions` (invariant 7).
    @Model final class Step {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var index: Int = 0
        var textLaTeX: String = ""
        var establishes: String = ""
        var confidenceRaw: String = Confidence.fallback.rawValue
        var attempt: ProofAttempt?

        @Relationship(deleteRule: .cascade, inverse: \StepRevision.step)
        var revisions: [StepRevision]? = []
        @Relationship(deleteRule: .cascade, inverse: \Review.step)
        var reviews: [Review]? = []
        @Relationship(deleteRule: .cascade, inverse: \Citation.step)
        var citations: [Citation]? = []
        @Relationship(deleteRule: .cascade, inverse: \StepComment.step)
        var comments: [StepComment]? = []
        var statements: [Statement]? = []

        init(index: Int = 0, textLaTeX: String = "", establishes: String = "", confidence: Confidence = .standard) {
            self.index = index
            self.textLaTeX = textLaTeX
            self.establishes = establishes
            self.confidenceRaw = confidence.rawValue
        }

        var confidence: Confidence {
            get { Confidence(stored: confidenceRaw) }
            set { confidenceRaw = newValue.rawValue }
        }

        /// The current revision: the newest, ties broken by ID so every reader agrees.
        var latestRevision: StepRevision? {
            (revisions ?? []).max { ($0.createdAt, $0.stableID.uuidString) < ($1.createdAt, $1.stableID.uuidString) }
        }
    }

    @Model final class StepRevision {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var authorKindRaw: String?
        var authorID: UUID?
        var textLaTeX: String = ""
        var establishes: String = ""
        var step: Step?

        init(author: Author? = nil, textLaTeX: String = "", establishes: String = "") {
            self.textLaTeX = textLaTeX
            self.establishes = establishes
            self.author = author
        }

        var author: Author? {
            get { Author(kind: authorKindRaw, id: authorID) }
            set { authorKindRaw = newValue?.stored.kind; authorID = newValue?.stored.id }
        }
    }

    /// A person's verdict on one revision of a step. A ✗ or ? stays open until a new revision or a person's
    /// dismissal with a reason (invariant 11).
    @Model final class Review {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var reviewerID: UUID?
        var verdictRaw: String = ReviewVerdict.fallback.rawValue
        var comments: String = ""
        var revisionReviewedID: UUID?
        var dismissalReason: String?
        var dismissedByID: UUID?
        var dismissedAt: Date?
        /// Set when the reviewer withdrew their own ✓; it then stops counting but stays in the history. A ✗ or ?
        /// is never withdrawn, only dismissed with a reason.
        var withdrawnAt: Date?
        var step: Step?

        init(reviewer: PersonID? = nil, verdict: ReviewVerdict = .unclear, revisionReviewedID: UUID? = nil, comments: String = "") {
            self.reviewerID = reviewer?.rawValue
            self.verdictRaw = verdict.rawValue
            self.revisionReviewedID = revisionReviewedID
            self.comments = comments
        }

        var verdict: ReviewVerdict {
            get { ReviewVerdict(stored: verdictRaw) }
            set { verdictRaw = newValue.rawValue }
        }

        var reviewer: PersonID? { reviewerID.map(PersonID.init) }
    }

    /// A note on a step, written on one revision. It carries no verdict: it never checks, objects or dismisses.
    @Model final class StepComment {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var authorKindRaw: String?
        var authorID: UUID?
        var body: String = ""
        /// The revision its author was reading.
        var revisionID: UUID?
        var step: Step?

        init(author: Author? = nil, body: String = "", revisionID: UUID? = nil) {
            self.body = body
            self.revisionID = revisionID
            self.author = author
        }

        var author: Author? {
            get { Author(kind: authorKindRaw, id: authorID) }
            set { authorKindRaw = newValue?.stored.kind; authorID = newValue?.stored.id }
        }
    }

    /// A citation as written. Model citations start unverified and are never shown as links until resolved
    /// (invariant 6).
    @Model final class Citation {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var rawText: String = ""
        var statusRaw: String = CitationStatus.fallback.rawValue
        var resolvedURL: String?
        var indexName: String?
        var step: Step?

        init(rawText: String = "", status: CitationStatus = .unverified) {
            self.rawText = rawText
            self.statusRaw = status.rawValue
        }

        var status: CitationStatus {
            get { CitationStatus(stored: statusRaw) }
            set { statusRaw = newValue.rawValue }
        }
    }

    /// Two attempts' steps paired by what they establish. Attempts are referenced by stable ID.
    @Model final class Alignment {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var attemptAID: UUID?
        var attemptBID: UUID?
        var rowsJSON: Data?
        var correctedByUser: Bool = false
        var problem: Problem?

        init(attemptAID: UUID? = nil, attemptBID: UUID? = nil) {
            self.attemptAID = attemptAID
            self.attemptBID = attemptBID
        }

        var rows: [AlignmentRow] {
            get { JSONColumn.decode([AlignmentRow].self, from: rowsJSON) ?? [] }
            set { rowsJSON = JSONColumn.encode(newValue) }
        }
    }
}
