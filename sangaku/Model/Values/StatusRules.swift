import Foundation

/// Everything a statement's own status depends on, gathered from the store by `StatusInputs.make(for:people:)`.
nonisolated struct StatusInputs: Hashable, Sendable {
    nonisolated struct Lean: Hashable, Sendable {
        /// The check ran on exactly the stored source (`checkedAt` set, the digest matches, the statement part is
        /// the start of the source) and its messages could be read. Otherwise "no errors" would be indistinguishable
        /// from "never checked".
        var ran: Bool
        var errorCount: Int
        var sorryCount: Int
        /// The app's kernel check of this statement's declaration. An empty axiom list counts only when it reported.
        var axiomCheck: AxiomCheck
        /// The code names no other statement in its statement part, and in its proof only statements this one uses,
        /// directly or through them. A result naming a statement it no longer uses (one deleted, or a dependency
        /// removed) does not count, since the cap no longer covers it (invariant 13).
        var namesOnlyUsed: Bool = true
        /// A person's latest fidelity review of the *current* Lean statement, on the current informal wording, says
        /// it matches.
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

    /// Rule 2: the check ran on the stored source with no errors and no `sorry`, the kernel check reported its axioms
    /// and every one is standard, its code names only what it uses, and a person confirmed the Lean statement. The one
    /// test the status and every Lean card read, so they cannot disagree.
    static func leanVerifies(_ lean: StatusInputs.Lean?) -> Bool {
        guard let lean, lean.ran, lean.errorCount == 0, lean.sorryCount == 0, lean.fidelityConfirmed, lean.namesOnlyUsed,
              case .ran(_, let axioms) = lean.axiomCheck else { return false }
        return Set(axioms).isSubset(of: standardAxioms)
    }

    static func ownStatus(_ inputs: StatusInputs) -> StatementStatus {
        if inputs.refutationAccepted { return .refuted }
        if leanVerifies(inputs.lean) { return .formallyVerified }
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
            let ran = result.checkedAt != nil && result.messagesAreReadable && !current.isEmpty
                && result.source.hasPrefix(current) && result.checkedDigest == TextDigest(of: result.source).hex
            // A result read for another statement's declaration never counts for this one.
            let axiomCheck: AxiomCheck = switch result.axiomCheck {
            case .ran(let name, _) where name == LeanNaming.declaration(for: statement.stableID): result.axiomCheck
            default: .notRun
            }
            let reviews = (statement.fidelityReviews ?? []).map {
                FidelityRule.Review(reviewer: $0.reviewerID, leanStatement: $0.leanStatementSource,
                                    informal: $0.informalWording, verdict: $0.verdict, createdAt: $0.createdAt,
                                    withdrawn: $0.withdrawnAt != nil)
            }
            inputs.lean = Lean(ran: ran, errorCount: result.errors.count, sorryCount: result.sorryCount,
                               axiomCheck: axiomCheck, namesOnlyUsed: statement.namesOnlyUsed(in: result.storedSource),
                               fidelityConfirmed: FidelityRule.confirmed(reviews, people: people, leanStatement: current,
                                                                         informal: statement.statementLaTeX))
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

extension Statement {
    /// Everything this statement uses, directly or through what those use.
    var usesClosure: [Statement] {
        var seen: Set<UUID> = [stableID]
        var found: [Statement] = []
        var queue = uses ?? []
        while let next = queue.popLast() {
            guard seen.insert(next.stableID).inserted else { continue }
            found.append(next)
            queue.append(contentsOf: next.uses ?? [])
        }
        return found
    }

    /// The statement part names no other statement's code, and the proof only this statement's and those it uses.
    func namesOnlyUsed(in source: LeanSource?) -> Bool {
        guard let source else { return true }
        let own = LeanNaming.short(stableID)
        let used = Set(usesClosure.map { LeanNaming.short($0.stableID) } + [own])
        return LeanGate.references(in: source.statementPart).isSubset(of: [own])
            && LeanGate.references(in: source.proofPart).isSubset(of: used)
    }
}

/// Whether a person confirmed that a Lean statement says what the informal one says (invariant 12): of the people's
/// reviews given on exactly this Lean statement and this informal wording and not withdrawn, the latest says it
/// matches. Reviews given at the same instant stand together, so a tie confirms only if every one of them matches.
nonisolated enum FidelityRule {
    nonisolated struct Review: Hashable, Sendable {
        var reviewer: UUID?
        var leanStatement: String
        var informal: String
        var verdict: FidelityVerdict
        var createdAt: Date
        var withdrawn = false
    }

    static func confirmed(_ reviews: [Review], people: Set<UUID>, leanStatement: String, informal: String) -> Bool {
        let current = reviews.filter {
            $0.reviewer.map(people.contains) ?? false && !leanStatement.isEmpty && !$0.withdrawn
                && $0.leanStatement == leanStatement && $0.informal == informal
        }
        guard let latest = current.map(\.createdAt).max() else { return false }
        return current.filter { $0.createdAt == latest }.allSatisfy { $0.verdict == .matches }
    }
}
