import Foundation
import SwiftData

extension SangakuSchemaV1 {
    /// An approach to a problem. Dead ends keep the reason they died; `reasonForModels` is the exact text
    /// sent to models when `includeReasonInContext` is on. A fork reads its parent's messages up to `forkedFrom`
    /// (`BranchHistory`); nothing is copied. Every text and state here is written by a person (`BranchManager`).
    @Model final class Branch {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var name: String = ""
        var stateRaw: String = BranchState.fallback.rawValue
        var reason: String?
        var reasonForModels: String?
        var includeReasonInContext: Bool = false
        var problem: Problem?
        /// Who last retired or reopened the branch, and when.
        var stateChangedByID: UUID?
        var stateChangedAt: Date?
        /// Who wrote `reason`, when, and the message it was started from, if any.
        var reasonByID: UUID?
        var reasonAt: Date?
        var reasonFromMessageID: UUID?
        /// The same for `reasonForModels`.
        var modelTextByID: UUID?
        var modelTextAt: Date?
        var modelTextFromMessageID: UUID?

        /// The branch that owns `forkedFrom`, set with it. History follows `forkedFrom.branch`; this only shows that
        /// the branch was forked, so a fork whose fork point is gone fails closed (`BranchHistory.Fault`).
        @Relationship(deleteRule: .nullify)
        var parent: Branch?
        @Relationship(deleteRule: .cascade, inverse: \Branch.parent)
        var children: [Branch]? = []
        @Relationship(deleteRule: .nullify)
        var forkedFrom: Message?
        @Relationship(deleteRule: .cascade, inverse: \Message.branch)
        var messages: [Message]? = []

        init(name: String = "", state: BranchState = .live) {
            self.name = name
            self.stateRaw = state.rawValue
        }

        var state: BranchState {
            get { BranchState(stored: stateRaw) }
            set { stateRaw = newValue.rawValue }
        }

        /// This branch's own messages, oldest first; a fork's inherited ones are in `visibleHistory`.
        var sortedMessages: [Message] {
            (messages ?? []).sorted { ($0.createdAt, $0.stableID.uuidString) < ($1.createdAt, $1.stableID.uuidString) }
        }

        /// What models are told about this branch as a dead end (`BranchReasons.textForModels`). The Branches panel
        /// shows this same text.
        var textForModels: String {
            BranchReasons.textForModels(forModels: reasonForModels, forPeople: reason)
        }
    }

    @Model final class Message {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var authorKindRaw: String?
        var authorID: UUID?
        var bodyLaTeX: String = ""
        var kindRaw: String = MessageKind.fallback.rawValue
        /// Set when streaming was stopped; the partial output is kept.
        var interrupted: Bool = false
        /// The messages this one was written from: a model reply's prompt, every attempt a referee saw, the
        /// messages a person quoted. `ContextBuilder` follows these links to keep independent attempts apart
        /// (invariant 4).
        var derivedFromIDs: [UUID] = []
        var branch: Branch?

        @Relationship(deleteRule: .cascade, inverse: \RequestRecord.message)
        var request: RequestRecord?
        /// For a prompt that started a fan-out.
        @Relationship(deleteRule: .cascade, inverse: \FanOut.request)
        var fanOut: FanOut?
        /// For an attempt message.
        @Relationship(deleteRule: .cascade, inverse: \ProofAttempt.message)
        var proofAttempt: ProofAttempt?
        @Relationship(deleteRule: .nullify, inverse: \Branch.forkedFrom)
        var forks: [Branch]? = []
        /// For a formalizer's message: the Lean code it drafted.
        @Relationship(deleteRule: .cascade, inverse: \LeanDraft.message)
        var leanDraft: LeanDraft?
        /// For a computation message: the cell it carries.
        @Relationship(deleteRule: .cascade, inverse: \ComputeCell.message)
        var computeCell: ComputeCell?

        init(author: Author? = nil, bodyLaTeX: String = "", kind: MessageKind = .prompt) {
            self.bodyLaTeX = bodyLaTeX
            self.kindRaw = kind.rawValue
            self.author = author
        }

        var kind: MessageKind {
            get { MessageKind(stored: kindRaw) }
            set { kindRaw = newValue.rawValue }
        }

        var author: Author? {
            get { Author(kind: authorKindRaw, id: authorID) }
            set { authorKindRaw = newValue?.stored.kind; authorID = newValue?.stored.id }
        }
    }

    /// Exactly what a model saw for one request (spec: View context), and what it cost.
    @Model final class RequestRecord {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var providerID: String = ""
        /// The model asked. `answeredModelID` is the model the provider says answered.
        var modelID: String = ""
        var answeredModelID: String?
        var parametersJSON: Data?
        var promptVersion: String = ""
        /// The text of every block sent, in order, with the cache breakpoint marked.
        @Attribute(.externalStorage) var contextText: String = ""
        var droppedItemsJSON: Data?
        /// The local estimate made before sending, kept to calibrate later estimates against the actual count.
        var estimatedInputTokens: Int = 0
        /// Input tokens billed at the full rate (the API's `input_tokens`, which excludes cached tokens).
        var inputTokens: Int = 0
        /// Input tokens read from the prompt cache.
        var cachedInputTokens: Int = 0
        /// Input tokens written to the prompt cache.
        var cacheWriteTokens: Int = 0
        var outputTokens: Int = 0
        /// The provider reported final usage. False when the reply was stopped, failed or cut short: the counts
        /// are then a lower bound.
        var usageReported: Bool = false
        /// In US dollars, from the catalog's prices. Nil when the model's price is unknown; never a made-up 0.
        var estimatedCost: Double?
        /// The provider's stop reason (`end_turn`, `max_tokens`, `refusal`, …), or `app_quit` / `orphaned`.
        var stopReason: String?
        /// For a refusal: the category the provider gave.
        var stopCategory: String?
        var errorKind: String?
        var errorMessage: String?
        /// Set when the request ended, however it ended. Nil on a record whose request never finished.
        var finishedAt: Date?
        /// For a request with structured output (an attempt or a referee): how its output was read. Nil for prose.
        var parseStateRaw: String?
        /// The model's output exactly as it arrived, for a request with structured output. The message keeps what
        /// was read from it; this keeps everything, so nothing is lost when only part could be read.
        @Attribute(.externalStorage) var rawOutput: String?
        /// The record's one owner: the message it produced, or the comparison it aligned.
        var message: Message?
        var alignment: Alignment?

        init() {}

        /// Nil for a prose request.
        var parseState: ParseState? {
            get { parseStateRaw.map { ParseState(stored: $0) } }
            set { parseStateRaw = newValue?.rawValue }
        }

        var droppedItems: [DroppedContextItem] {
            get { JSONColumn.decode([DroppedContextItem].self, from: droppedItemsJSON) ?? [] }
            set { droppedItemsJSON = JSONColumn.encode(newValue) }
        }

        /// Dropped items stored but unreadable: View context must say so rather than claim nothing was dropped.
        var droppedItemsAreReadable: Bool {
            droppedItemsJSON == nil || JSONColumn.decode([DroppedContextItem].self, from: droppedItemsJSON) != nil
        }

        var usage: TokenUsage {
            TokenUsage(input: inputTokens, cacheWrite: cacheWriteTokens, cacheRead: cachedInputTokens, output: outputTokens)
        }
    }

    /// One request sent to several provers, optionally followed by a referee.
    @Model final class FanOut {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var visibilityRaw: String = FanOutVisibility.fallback.rawValue
        var refereeSlotID: UUID?
        var request: Message?

        @Relationship(deleteRule: .nullify, inverse: \ProofAttempt.fanOut)
        var attempts: [ProofAttempt]? = []
        @Relationship(deleteRule: .cascade, inverse: \RefereeVerdict.fanOut)
        var verdicts: [RefereeVerdict]? = []

        init(visibility: FanOutVisibility = .independent) {
            self.visibilityRaw = visibility.rawValue
        }

        var visibility: FanOutVisibility {
            get { FanOutVisibility(stored: visibilityRaw) }
            set { visibilityRaw = newValue.rawValue }
        }
    }

    /// A referee's verdict on one attempt: complete, or a gap at the listed steps.
    @Model final class RefereeVerdict {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var outcomeRaw: String = RefereeOutcome.fallback.rawValue
        var gapStepIndices: [Int] = []
        var rationale: String = ""
        /// True when the attempt this verdict judges reached the referee partial (stopped, cut off or failed).
        var sawPartialAttempt: Bool = false
        var refereeSlotID: UUID?
        /// The referee message that gave this verdict. A fan-out refereed twice keeps both sets.
        var messageID: UUID?
        /// When the referee's request was made: the verdict covers each step's text as it stood then. Without it
        /// the verdict covers no step (rule 4 fails closed).
        var requestedAt: Date?
        var fanOut: FanOut?

        @Relationship(deleteRule: .nullify, inverse: \ProofAttempt.verdicts)
        var attempt: ProofAttempt?

        init(outcome: RefereeOutcome = .gap, gapStepIndices: [Int] = [], rationale: String = "") {
            self.outcomeRaw = outcome.rawValue
            self.gapStepIndices = gapStepIndices
            self.rationale = rationale
        }

        var outcome: RefereeOutcome {
            get { RefereeOutcome(stored: outcomeRaw) }
            set { outcomeRaw = newValue.rawValue }
        }
    }
}
