import Foundation

/// Everything `ContextBuilder` may use, copied out of the store on the main actor as plain values so a request
/// never carries a `@Model` object across actors.
nonisolated struct ProblemSnapshot: Hashable, Sendable {
    nonisolated struct StatementDigest: Hashable, Sendable {
        var id: UUID
        var createdAt: Date
        var label: String
        var statementLaTeX: String
        /// For a refuted claim, the refutation note; for an adopted lemma, its status in words.
        var note: String?
    }

    nonisolated struct DeadEndDigest: Hashable, Sendable {
        var id: UUID
        var createdAt: Date
        var name: String
        /// Exactly what models are told (`Branch.textForModels`).
        var text: String
    }

    nonisolated struct SlotDigest: Hashable, Sendable {
        var id: ModelSlotID
        var letter: String
        var providerID: String
        var modelID: String
        var role: SlotRole
    }

    nonisolated struct StepDigest: Hashable, Sendable {
        var index: Int
        var textLaTeX: String
        var establishes: String
        var confidence: Confidence
        /// The person who wrote the current text, when a person revised the step (invariant 7).
        var revisedBy: Author? = nil
    }

    /// A verdict a referee message gave, as later models are told it.
    nonisolated struct VerdictDigest: Hashable, Sendable {
        var attemptLetter: String
        var outcome: RefereeOutcome
        var gapStepIndices: [Int]
        var rationale: String
        var sawPartialAttempt: Bool
    }

    nonisolated struct MessageDigest: Hashable, Sendable, Identifiable {
        var id: UUID
        var createdAt: Date
        var author: Author?
        var kind: MessageKind
        var body: String
        var steps: [StepDigest] = []
        var outcome: MessageOutcome = .complete
        var derivedFromIDs: [UUID] = []
        /// For an attempt: the fan-out it belongs to.
        var fanOutID: UUID?
        /// For a referee message: the verdicts it gave, in attempt order.
        var verdicts: [VerdictDigest] = []
    }

    nonisolated struct FanOutDigest: Hashable, Sendable, Identifiable {
        var id: UUID
        var visibility: FanOutVisibility
        var requestMessageID: UUID?
        var attemptMessageIDs: [UUID]
        var refereeSlotID: UUID?
    }

    var problemID: UUID
    var title: String
    var statementLaTeX: String
    var allowedProviderIDs: [String]
    var notation: NotationRegistry
    /// Every statement that is not refuted, not the problem's theorem and not a conjecture, with its displayed
    /// status (after the cap) and why it is held down as the note.
    var adoptedLemmas: [StatementDigest] = []
    var refutedClaims: [StatementDigest] = []
    var deadEnds: [DeadEndDigest] = []
    var branchID: UUID
    /// The branch's messages, oldest first.
    var messages: [MessageDigest] = []
    var fanOuts: [FanOutDigest] = []
    var slots: [SlotDigest] = []
    /// Names of people by stable ID.
    var people: [UUID: String] = [:]
    /// The person using the app: their messages go to the model without an author label.
    var meID: UUID?

    func message(_ id: UUID) -> MessageDigest? { messages.first { $0.id == id } }
    func fanOut(_ id: UUID) -> FanOutDigest? { fanOuts.first { $0.id == id } }
    func slot(_ id: ModelSlotID) -> SlotDigest? { slots.first { $0.id == id } }
}

extension ProblemSnapshot.SlotDigest {
    init(_ slot: ModelSlot) {
        self.init(id: slot.slotID, letter: slot.letter, providerID: slot.providerID, modelID: slot.modelID, role: slot.role)
    }
}

extension ProblemSnapshot {
    /// Reads a problem and one of its branches. `liveMessageIDs` are replies still streaming: they are never
    /// context. `people` decides who counts as a person (invariant 1: only a person accepts a refutation).
    static func make(problem: Problem, branch: Branch, notation: NotationRegistry, people: [Person],
                     liveMessageIDs: Set<UUID>) -> ProblemSnapshot {
        let personIDs = Set(people.map(\.stableID))
        var snapshot = ProblemSnapshot(
            problemID: problem.stableID, title: problem.title, statementLaTeX: problem.statementLaTeX,
            allowedProviderIDs: problem.allowedProviderIDs, notation: notation, branchID: branch.stableID)

        let graph = StatementGraphState.read(problem: problem, people: personIDs)
        snapshot.adoptedLemmas = graph.adoptedLemmas.map {
            StatementDigest(id: $0.id, createdAt: $0.createdAt, label: $0.label, statementLaTeX: $0.statementLaTeX,
                            note: $0.contextNote)
        }
        snapshot.refutedClaims = graph.refutedClaims.map {
            StatementDigest(id: $0.id, createdAt: $0.createdAt, label: $0.label, statementLaTeX: $0.statementLaTeX,
                            note: $0.refutationNote)
        }

        snapshot.deadEnds = problem.sortedBranches
            .filter { $0.state == .deadEnd && $0.includeReasonInContext }
            .map { DeadEndDigest(id: $0.stableID, createdAt: $0.createdAt, name: $0.name, text: $0.textForModels) }

        let messages = branch.sortedMessages
        let letters = Dictionary(problem.sortedModelSlots.map { ($0.stableID, $0.letter) }, uniquingKeysWith: { first, _ in first })
        var verdictsByMessage: [UUID: [VerdictDigest]] = [:]
        for message in messages {
            for verdict in message.fanOut?.verdicts ?? [] {
                guard let messageID = verdict.messageID, let attemptMessage = verdict.attempt?.message else { continue }
                let letter = if case .model(let slot) = attemptMessage.author { letters[slot.rawValue] ?? "?" } else { "?" }
                verdictsByMessage[messageID, default: []].append(VerdictDigest(
                    attemptLetter: letter, outcome: verdict.outcome, gapStepIndices: verdict.gapStepIndices,
                    rationale: verdict.rationale, sawPartialAttempt: verdict.sawPartialAttempt))
            }
        }
        snapshot.messages = messages.map { message in
            MessageDigest(
                id: message.stableID, createdAt: message.createdAt, author: message.author, kind: message.kind,
                body: message.bodyLaTeX,
                steps: (message.proofAttempt?.sortedSteps ?? []).map {
                    StepDigest(index: $0.index, textLaTeX: $0.textLaTeX, establishes: $0.establishes,
                               confidence: $0.confidence,
                               revisedBy: StepProvenance(revisions: ($0.revisions ?? []).map { RevisionFact($0) }).revisingPerson)
                },
                outcome: message.outcome(isStreaming: liveMessageIDs.contains(message.stableID)),
                derivedFromIDs: message.derivedFromIDs,
                fanOutID: message.proofAttempt?.fanOut?.stableID,
                verdicts: (verdictsByMessage[message.stableID] ?? []).sorted { $0.attemptLetter < $1.attemptLetter })
        }
        snapshot.fanOuts = messages.compactMap { message in
            guard let fanOut = message.fanOut else { return nil }
            // A to-many relationship has no order: attempts are taken in the order they were written.
            let attempts = (fanOut.attempts ?? []).compactMap(\.message).sorted { $0.createdAt < $1.createdAt }
            return FanOutDigest(id: fanOut.stableID, visibility: fanOut.visibility, requestMessageID: message.stableID,
                                attemptMessageIDs: attempts.map(\.stableID), refereeSlotID: fanOut.refereeSlotID)
        }
        snapshot.slots = problem.sortedModelSlots.map {
            SlotDigest(id: $0.slotID, letter: $0.letter, providerID: $0.providerID, modelID: $0.modelID, role: $0.role)
        }
        snapshot.people = Dictionary(people.map { ($0.stableID, $0.name) }, uniquingKeysWith: { first, _ in first })
        snapshot.meID = Person.me(among: people)?.stableID
        return snapshot
    }
}

nonisolated extension ProblemSnapshot {
    /// One attempt of a fan-out that is about to be sent.
    nonisolated struct PendingAttempt: Hashable, Sendable {
        var messageID: UUID
        var slot: ModelSlotID
        var createdAt: Date
    }

    /// The snapshot as it will be once a fan-out is sent: its prompt, its attempts still streaming, and the fan-out.
    /// Every recipient's context is built against this before anything is written, so a refused send changes nothing.
    func addingFanOut(id: UUID, visibility: FanOutVisibility, refereeSlotID: UUID?, promptID: UUID, promptText: String,
                      promptAuthor: Author?, promptCreatedAt: Date, attempts: [PendingAttempt]) -> ProblemSnapshot {
        var snapshot = self
        snapshot.messages.append(MessageDigest(id: promptID, createdAt: promptCreatedAt, author: promptAuthor,
                                               kind: .prompt, body: promptText))
        for attempt in attempts {
            snapshot.messages.append(MessageDigest(id: attempt.messageID, createdAt: attempt.createdAt,
                                                   author: .model(attempt.slot), kind: .attempt, body: "",
                                                   outcome: .streaming, derivedFromIDs: [promptID], fanOutID: id))
        }
        snapshot.fanOuts.append(FanOutDigest(id: id, visibility: visibility, requestMessageID: promptID,
                                             attemptMessageIDs: attempts.map(\.messageID), refereeSlotID: refereeSlotID))
        return snapshot
    }
}
