import Foundation

/// Everything a statement's own status depends on, gathered from the store by `StatusInputs.make(for:people:)`.
nonisolated struct StatusInputs: Hashable, Sendable {
    nonisolated struct Lean: Hashable, Sendable {
        /// The check actually ran (`checkedAt` set, source present) and its messages could be read. Otherwise
        /// "no errors, no axioms" would be indistinguishable from "never checked".
        var ran: Bool
        var errorCount: Int
        var sorryCount: Int
        var axioms: [String]
        /// A person's latest fidelity review of the *current* Lean statement says it matches.
        var fidelityConfirmed: Bool
    }

    nonisolated struct SourceStep: Hashable, Sendable {
        /// A person's ✓ on the step's current revision.
        var checkedOnCurrentRevision: Bool
        /// A ✗ or ? on the current revision, not dismissed (invariant 11).
        var hasOpenObjection: Bool
    }

    var refutationAccepted = false
    var lean: Lean?
    var sourceSteps: [SourceStep] = []
    /// For every attempt holding a source step, the standing (newest) referee verdict is "complete" with no gap at
    /// those steps.
    var refereePassed = false
}

/// The statement's own status: the first of the spec's rules that matches. The cap by dependencies is applied
/// on top of this by `StatusDerivation`.
nonisolated enum StatusRules {
    /// The axioms a Lean proof may rely on (invariant 12). Anything else, `sorryAx` included, disqualifies it.
    static let standardAxioms: Set<String> = ["propext", "Classical.choice", "Quot.sound"]

    static func ownStatus(_ inputs: StatusInputs) -> StatementStatus {
        if inputs.refutationAccepted { return .refuted }
        if let lean = inputs.lean, lean.ran, lean.errorCount == 0, lean.sorryCount == 0,
           Set(lean.axioms).isSubset(of: standardAxioms), lean.fidelityConfirmed {
            return .formallyVerified
        }
        if !inputs.sourceSteps.isEmpty,
           inputs.sourceSteps.allSatisfy({ $0.checkedOnCurrentRevision && !$0.hasOpenObjection }) {
            return .humanChecked
        }
        if inputs.refereePassed { return .modelChecked }
        if !inputs.sourceSteps.isEmpty { return .sketched }
        return .proposed
    }
}

extension StatusInputs {
    /// Reads a statement's evidence. `people` holds the stable IDs of `Person` records: only they can check,
    /// accept a refutation or confirm fidelity (invariant 1).
    static func make(for statement: Statement, people: Set<UUID>) -> StatusInputs {
        var inputs = StatusInputs()
        func isPerson(_ id: UUID?) -> Bool { id.map(people.contains) ?? false }

        inputs.refutationAccepted = isPerson(statement.refutationAcceptedByID)

        if let result = statement.leanResult {
            let current = result.leanStatementSource
            let latest = (statement.fidelityReviews ?? [])
                .filter { isPerson($0.reviewerID) && !current.isEmpty && $0.leanStatementSource == current }
                .max { $0.createdAt < $1.createdAt }
            let ran = result.checkedAt != nil && !result.source.isEmpty && result.messagesAreReadable
            inputs.lean = Lean(ran: ran, errorCount: result.errors.count, sorryCount: result.sorryCount,
                               axioms: result.axioms, fidelityConfirmed: latest?.verdict == .matches)
        }

        let steps = make(sourceSteps: statement.sourceSteps ?? [], people: people)
        inputs.sourceSteps = steps.sourceSteps
        inputs.refereePassed = steps.refereePassed
        return inputs
    }

    /// Rules 3 to 5 for a run of steps: what a statement resting on exactly these steps earns. The Branches tree
    /// judges an attempt this way, so it and the theorem it might become cannot disagree. Rules 3 and 4 read the same
    /// per-step standing as the Review screen.
    static func make(sourceSteps steps: [Step], people: Set<UUID>) -> StatusInputs {
        make(steps: steps, standings: StepStandings.standings(of: steps, people: people))
    }

    /// The same, from standings already derived.
    static func make(steps: [Step], standings: [UUID: StepStanding]) -> StatusInputs {
        var inputs = StatusInputs()
        inputs.sourceSteps = steps.map { SourceStep(standings[$0.stableID]) }
        inputs.refereePassed = !steps.isEmpty && steps.allSatisfy { standings[$0.stableID]?.model.passes == true }
        return inputs
    }
}

nonisolated extension StatusInputs.SourceStep {
    /// A step with no standing is unchecked and unobjected.
    init(_ standing: StepStanding?) {
        self.init(checkedOnCurrentRevision: !(standing?.checks.isEmpty ?? true),
                  hasOpenObjection: !(standing?.openObjections.isEmpty ?? true))
    }
}

/// A referee's verdict on one attempt, as rule 4 reads it.
nonisolated struct VerdictFact: Hashable, Sendable {
    var createdAt: Date
    var outcome: RefereeOutcome
    var gapStepIndices: [Int]
    /// When the referee's request was made: the verdict covers each step's text as it stood then. Nil covers none.
    var requestedAt: Date? = nil
    var refereeID: UUID? = nil
}

nonisolated extension StatusRules {
    /// The verdict that stands for an attempt: the newest one, so a later gap overrides an earlier "complete"
    /// (and the other way round). Verdicts given at the same instant stand together, so a tie is a gap if any of
    /// them is, with every step they list, and covers only what the earliest of them saw.
    static func standingVerdict(_ verdicts: [VerdictFact]) -> VerdictFact? {
        guard let newest = verdicts.map(\.createdAt).max() else { return nil }
        let tied = verdicts.filter { $0.createdAt == newest }
        guard tied.count > 1 else { return tied.first }
        let isGap = tied.contains { $0.outcome == .gap }
        return VerdictFact(
            createdAt: newest, outcome: isGap ? .gap : .complete,
            gapStepIndices: Set(tied.flatMap(\.gapStepIndices)).sorted(),
            requestedAt: tied.contains { $0.requestedAt == nil } ? nil : tied.compactMap(\.requestedAt).min(),
            refereeID: tied.compactMap(\.refereeID).min { $0.uuidString < $1.uuidString })
    }

    /// Rule 4 for one step: the standing verdict is "complete", lists no gap at the step, and was requested no
    /// earlier than the step's current revision. A verdict covers only the text it saw.
    static func modelCheck(_ standing: VerdictFact?, stepIndex: Int, latestRevisionAt: Date?) -> ModelCheck {
        guard let standing else { return .noVerdict }
        let referee = standing.refereeID
        if standing.gapStepIndices.contains(stepIndex) { return .gapListed(referee: referee) }
        guard standing.outcome == .complete else { return .attemptHasGap(referee: referee) }
        guard let requestedAt = standing.requestedAt else { return .unknownBasis(referee: referee) }
        guard let latestRevisionAt, latestRevisionAt <= requestedAt else { return .revisedSince(referee: referee) }
        return .complete(referee: referee)
    }
}

extension ProofAttempt {
    var verdictFacts: [VerdictFact] {
        (verdicts ?? []).map {
            VerdictFact(createdAt: $0.createdAt, outcome: $0.outcome, gapStepIndices: $0.gapStepIndices,
                        requestedAt: $0.requestedAt, refereeID: $0.refereeSlotID)
        }
    }

    /// The verdict that stands for this attempt (see `StatusRules.standingVerdict`).
    var standingVerdict: VerdictFact? { StatusRules.standingVerdict(verdictFacts) }
}
