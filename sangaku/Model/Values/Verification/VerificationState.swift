import Foundation

/// Where a statement's Lean check stands, read from the same inputs as rule 2, so a card can never say more than the
/// statement's status (invariant 3). Only `verified` is rule 2 holding.
nonisolated enum LeanStanding: Hashable, Sendable, CaseIterable {
    case notChecked
    case didNotCompile
    /// Its proof names a statement this one does not use, or its statement part names another statement's code.
    case namesUnusedStatement
    case axiomCheckMissing
    /// Compiles, but with a `sorry` or an axiom beyond the standard three.
    case incomplete
    /// Compiles cleanly; no person has confirmed the Lean statement yet.
    case awaitingFidelity
    /// A person found the Lean statement says something else.
    case statementDiffers
    case verified

    static func of(_ lean: StatusInputs.Lean?, latestVerdict: FidelityVerdict?) -> LeanStanding {
        guard let lean, lean.ran else { return .notChecked }
        if StatusRules.leanVerifies(lean) { return .verified }
        if lean.errorCount > 0 { return .didNotCompile }
        if !lean.namesOnlyUsed { return .namesUnusedStatement }
        guard case .ran(_, let axioms) = lean.axiomCheck else { return .axiomCheckMissing }
        if lean.sorryCount > 0 || !Set(axioms).isSubset(of: StatusRules.standardAxioms) { return .incomplete }
        return latestVerdict == .differs ? .statementDiffers : .awaitingFidelity
    }
}

/// Whether a person confirmed the checked Lean statement, as the panel says it.
nonisolated enum FidelityStanding: Hashable, Sendable {
    case pending
    case confirmed(by: UUID?)
    case differs(by: UUID?)
    /// Reviews exist, but for an earlier Lean statement or wording.
    case outdated

    /// Who gave the review that stands, if one does.
    var reviewer: UUID? {
        switch self {
        case .confirmed(let person), .differs(let person): person
        case .pending, .outdated: nil
        }
    }
}

/// One statement's Lean facts, for a card.
nonisolated struct LeanFacts: Hashable, Sendable {
    var statementID: UUID
    var label: String
    var standing: LeanStanding
    var fidelity: FidelityStanding
    var source: LeanSource?
    var errors: [LeanMessage]
    var sorryLocations: [LeanLocation]
    /// Nil when the axiom line did not report.
    var axioms: [String]?
    var checkedAt: Date?
    var leanVersion: String
    var mathlibRev: String
    var sourceAuthor: Author?

    var nonstandardAxioms: [String] { (axioms ?? []).filter { !StatusRules.standardAxioms.contains($0) } }
}

/// One run of a computation, for a card.
nonisolated struct EvidenceFact: Hashable, Sendable, Identifiable {
    var id: UUID
    var statementID: UUID
    var tool: EvidenceTool
    var scope: String
    var outcome: RunOutcome
    var verdict: CellVerdict
    /// What followed the result line: the counterexample, or why it is inconclusive.
    var detail: String
    var runByID: UUID?
    var createdAt: Date
    var seconds: Double
    var truncated: Bool
    var code: String
    var output: String
    var errorText: String
    /// A completed run that reported a counterexample, on a statement no person has refuted yet.
    var canRefute: Bool
}

/// One citation of a step, for a chip or a card.
nonisolated struct CitationFact: Hashable, Sendable, Identifiable {
    var id: UUID
    var stepID: UUID
    var stepIndex: Int
    var text: String
    var status: CitationStatus
    /// Only for a found citation with an https link to an index (invariant 6).
    var link: URL?
    var detail: String?
    var matchedTitle: String?
    var indexName: String?
    /// What the index returned for a found citation: authors as listed, and the year.
    var matchedAuthors: [String] = []
    var matchedYear: Int?
}

/// What the verification cards show for a problem: each statement's Lean facts and evidence. Built from the store on
/// every read, like `StatementGraphState`.
nonisolated struct VerificationState: Hashable, Sendable {
    var lean: [UUID: LeanFacts] = [:]
    var evidence: [UUID: [EvidenceFact]] = [:]
}

extension VerificationState {
    static func read(problem: Problem, people: Set<UUID>) -> VerificationState {
        var state = VerificationState()
        for statement in problem.statements ?? [] {
            state.lean[statement.stableID] = LeanFacts.read(statement, people: people)
            state.evidence[statement.stableID] = EvidenceFact.runs(of: statement, people: people)
        }
        return state
    }
}

extension Evidence {
    /// Newest first: by time, then by ID, so runs recorded at one instant always come in the same order.
    static func newestFirst(_ first: Evidence, _ second: Evidence) -> Bool {
        (first.createdAt, first.stableID.uuidString) > (second.createdAt, second.stableID.uuidString)
    }
}

extension ComputeCell {
    /// The cell's newest run (`Evidence.newestFirst`).
    var latestRun: Evidence? { (runs ?? []).sorted(by: Evidence.newestFirst).first }
}

extension LeanFacts {
    static func read(_ statement: Statement, people: Set<UUID>) -> LeanFacts {
        let inputs = StatusInputs.make(for: statement, people: people)
        let result = statement.leanResult
        let current = result?.leanStatementSource ?? ""
        let reviews = (statement.fidelityReviews ?? []).filter {
            $0.reviewerID.map(people.contains) ?? false && $0.withdrawnAt == nil
        }
        let onCurrent = reviews.filter { !current.isEmpty && $0.leanStatementSource == current && $0.informalWording == statement.statementLaTeX }
        let latest = onCurrent.max { ($0.createdAt, $0.stableID.uuidString) < ($1.createdAt, $1.stableID.uuidString) }
        let fidelity: FidelityStanding = if let latest {
            latest.verdict == .matches ? .confirmed(by: latest.reviewerID) : .differs(by: latest.reviewerID)
        } else if !reviews.isEmpty {
            .outdated
        } else {
            .pending
        }
        let axioms: [String]? = if case .ran(_, let list) = inputs.lean?.axiomCheck { list } else { nil }
        return LeanFacts(
            statementID: statement.stableID, label: statement.label,
            standing: LeanStanding.of(inputs.lean, latestVerdict: latest?.verdict), fidelity: fidelity,
            source: result?.storedSource, errors: (result?.messages ?? []).filter { $0.severity == "error" },
            sorryLocations: result?.sorryLocations ?? [], axioms: axioms, checkedAt: result?.checkedAt,
            leanVersion: result?.leanVersion ?? "", mathlibRev: result?.mathlibRev ?? "",
            sourceAuthor: result?.sourceAuthor)
    }
}

extension EvidenceFact {
    /// A statement's runs, newest first.
    static func runs(of statement: Statement, people: Set<UUID>) -> [EvidenceFact] {
        let refuted = statement.refutationAcceptedByID.map(people.contains) ?? false
        return (statement.evidence ?? []).sorted(by: Evidence.newestFirst)
            .map { read($0, statement: statement.stableID, refuted: refuted) }
    }

    static func read(_ evidence: Evidence, statement: UUID, refuted: Bool) -> EvidenceFact {
        let reading = CellOutputReader.read(evidence.output)
        return EvidenceFact(
            id: evidence.stableID, statementID: statement, tool: evidence.tool, scope: evidence.scope,
            outcome: evidence.outcome, verdict: evidence.verdict,
            detail: evidence.verdict == reading.verdict ? reading.detail : "", runByID: evidence.runByID,
            createdAt: evidence.createdAt, seconds: evidence.durationSeconds, truncated: evidence.truncated,
            code: evidence.code, output: evidence.output, errorText: evidence.errorText,
            canRefute: !refuted && evidence.outcome == .completed && evidence.verdict == .counterexample)
    }
}

extension CitationFact {
    /// The citations of an attempt's steps, in step order, without those a person removed.
    static func read(_ attempt: ProofAttempt) -> [CitationFact] {
        attempt.sortedSteps.flatMap { step in
            (step.citations ?? []).filter { $0.removedAt == nil }
                .sorted { ($0.createdAt, $0.stableID.uuidString) < ($1.createdAt, $1.stableID.uuidString) }
                .map { citation in
                    CitationFact(id: citation.stableID, stepID: step.stableID, stepIndex: step.index, text: citation.rawText,
                                 status: citation.status,
                                 link: CitationRules.link(status: citation.status, url: citation.resolvedURL),
                                 detail: citation.lookupDetail, matchedTitle: citation.matchedTitle,
                                 indexName: citation.indexName, matchedAuthors: citation.matchedAuthors,
                                 matchedYear: citation.matchedYear)
                }
        }
    }
}
