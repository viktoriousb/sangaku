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

        /// The current revision's text and label. The step's own copies only mirror them, for a step with none.
        var currentText: String { latestRevision?.textLaTeX ?? textLaTeX }
        var currentEstablishes: String { latestRevision?.establishes ?? establishes }
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
        /// Who cited it: a model in its attempt, or a person.
        var authorKindRaw: String?
        var authorID: UUID?
        /// The last lookup: when, by whom, what was sent, the title of the matching document and what went wrong.
        var checkedAt: Date?
        var checkedByID: UUID?
        var lastQuery: String?
        var matchedTitle: String?
        var lookupDetail: String?
        /// Removed by a person: kept for provenance and hidden everywhere.
        var removedAt: Date?
        var removedByID: UUID?

        init(rawText: String = "", status: CitationStatus = .unverified, author: Author? = nil) {
            self.rawText = rawText
            self.statusRaw = status.rawValue
            self.author = author
        }

        var status: CitationStatus {
            get { CitationStatus(stored: statusRaw) }
            set { statusRaw = newValue.rawValue }
        }

        var author: Author? {
            get { Author(kind: authorKindRaw, id: authorID) }
            set { authorKindRaw = newValue?.stored.kind; authorID = newValue?.stored.id }
        }
    }

    /// The comparison of two attempts, by stable ID: side 1 is `attemptAID` ("Attempt 1"), fixed by `SideOrder` when
    /// the comparison is made. It keeps three layers apart: the model's last good rows, a person's corrections and
    /// the person's blind verdict. The table is derived from them on every read (`ComparisonState`).
    @Model final class Alignment {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var attemptAID: UUID?
        var attemptBID: UUID?
        /// The model's rows from its last readable answer. Replaced whole by a new answer, never edited.
        var rowsJSON: Data?
        /// Set once a person has corrected the comparison (`correctionsJSON` is not empty).
        var correctedByUser: Bool = false
        /// A person's corrections, in the order made (`AlignmentCorrection`). Never touched by a model's answer.
        var correctionsJSON: Data?
        /// The request whose answer `rowsJSON` holds, the slot that gave it, and its summary.
        var modelRunID: UUID?
        var alignerSlotID: UUID?
        var modelSummary: String = ""
        /// The person's blind verdict: which attempt holds (`HoldsVerdict`), who said so, and when. Recording it
        /// reveals the authors of this comparison (invariant 9). It changes no review, check or status.
        var holdsRaw: String?
        var holdsByID: UUID?
        var holdsAt: Date?
        /// The alignment requests made for this comparison, with what each was sent.
        @Relationship(deleteRule: .cascade, inverse: \RequestRecord.alignment)
        var requests: [RequestRecord]? = []
        var problem: Problem?

        init(attemptAID: UUID? = nil, attemptBID: UUID? = nil) {
            self.attemptAID = attemptAID
            self.attemptBID = attemptBID
        }

        /// The model's rows; nil when none are stored or they cannot be read (see `rowsAreReadable`).
        var rows: [AlignmentRow]? {
            get { JSONColumn.decode([AlignmentRow].self, from: rowsJSON) }
            set { rowsJSON = newValue.flatMap { JSONColumn.encode($0) } }
        }

        /// Rows stored but unreadable: the comparison falls back to the pairing by label and says so.
        var rowsAreReadable: Bool { rowsJSON == nil || rows != nil }

        var corrections: [AlignmentCorrection] {
            get { JSONColumn.decode([AlignmentCorrection].self, from: correctionsJSON) ?? [] }
            set { correctionsJSON = JSONColumn.encode(newValue) }
        }

        /// Corrections stored but unreadable: they are not shown, and nothing writes over them.
        var correctionsAreReadable: Bool {
            correctionsJSON == nil || JSONColumn.decode([AlignmentCorrection].self, from: correctionsJSON) != nil
        }

        /// Nil while no verdict is recorded, and for a stored value that is not a known verdict.
        var holds: HoldsVerdict? { holdsRaw.flatMap(HoldsVerdict.init(rawValue:)) }
    }
}
