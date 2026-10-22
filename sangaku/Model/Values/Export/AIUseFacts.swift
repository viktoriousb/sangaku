import Foundation

/// A step as the AI-use statement names it: its number, and its attempt when the export holds several.
nonisolated struct AIUseStep: Hashable, Sendable, Comparable {
    /// 1 for the oldest attempt of the export.
    var attempt: Int
    var index: Int

    static func < (lhs: AIUseStep, rhs: AIUseStep) -> Bool { (lhs.attempt, lhs.index) < (rhs.attempt, rhs.index) }
}

/// Everything the AI-use statement may say, counted from an export's statements and the steps they rest on. Each
/// sentence of `AIUseStatement` is gated by one of these facts (invariant 8). Roles only: no name of a person or a
/// model, and no maker.
nonisolated struct AIUseFacts: Hashable, Sendable {
    /// What a referee's standing verdict says about the exported steps of one attempt (rule 4).
    nonisolated enum Verdict: Hashable, Sendable {
        /// "Complete": it covers `covered`, but not `revisedSince`, which changed after it was asked.
        case complete(covered: [AIUseStep], revisedSince: [AIUseStep])
        /// A gap at these steps, or somewhere unnamed: it vouches for no step.
        case gap(at: [AIUseStep], outsideExport: Bool)
        /// "Complete", but when it was asked is not recorded: it vouches for no step.
        case unknownBasis
    }

    nonisolated struct Referee: Hashable, Sendable {
        var attempt: Int
        /// The model that drafted the attempt was also its referee.
        var drafterWasReferee: Bool
        var verdict: Verdict
    }

    nonisolated struct LeanCheck: Hashable, Sendable {
        var label: String
        var standing: LeanStanding
        var codeAuthor: ExportActor
        /// A language model drafted Lean code for the statement, whoever wrote the code checked.
        var modelDrafted = false
    }

    nonisolated struct Computation: Hashable, Sendable {
        var label: String
        var tool: EvidenceTool
        var scope: String
        var verdict: CellVerdict
        var codeAuthor: ExportActor
        /// A person accepted a refutation of the statement.
        var statementRefuted: Bool
    }

    nonisolated struct Imported: Hashable, Sendable {
        var label: String
        var source: String
        /// The exported statements that rest on it, directly or through others.
        var assumedBy: [String]
        /// It was also verified in Lean here.
        var verifiedInLean = false
    }

    var scope: ExportScope
    var theoremLabel: String?
    var statementCount: Int
    var attemptCount: Int
    /// Every exported step, once, in order.
    var steps: [AIUseStep] = []
    var statedByModel: [String] = []
    var draftedByModel: [AIUseStep] = []
    var draftedByPerson: [AIUseStep] = []
    var draftedByUnknown: [AIUseStep] = []
    /// How many model slots drafted steps.
    var draftingModels = 0
    var revisedByPerson: [AIUseStep] = []
    var revisedByModel: [AIUseStep] = []
    var revisedByUnknown: [AIUseStep] = []
    /// Attempts that stopped before their end.
    var partialAttempts: [Int] = []
    var referees: [Referee] = []
    var checked: [AIUseStep] = []
    var objected: [AIUseStep] = []
    var unreviewed: [AIUseStep] = []
    var flagged: [AIUseStep] = []
    var lean: [LeanCheck] = []
    /// Statements never checked in Lean, refuted ones aside.
    var notInLean: [String] = []
    /// Runs whose code completed and reported a result.
    var computations: [Computation] = []
    /// Runs that did not complete, or completed without a result.
    var unfinishedRuns = 0
    var citationsFound = 0
    var citationsNotFound = 0
    var citationsUnchecked = 0
    /// The indexes found citations matched in, in order of first appearance.
    var foundIn: [String] = []
    var imported: [Imported] = []
    var refuted: [String] = []
    /// Messages written by language models that the export does not reproduce.
    var otherModelMessages = 0

    /// "All steps were checked by a person" may be said.
    var claimsAll: Bool { !steps.isEmpty && checked.count == steps.count && partialAttempts.isEmpty }
}

nonisolated extension AIUseFacts {
    static func make(_ snapshot: ExportSnapshot, scope: ExportScope) -> AIUseFacts {
        let statements = snapshot.statements(in: scope)
        let attempts = snapshot.attempts(in: scope)
        let attemptIDs = Set(attempts.map(\.id))
        let ordinal = snapshot.attemptNumbers(in: scope)
        var facts = AIUseFacts(scope: scope, theoremLabel: snapshot.theorem?.label, statementCount: statements.count,
                               attemptCount: attempts.count)

        // The exported steps, once each.
        var seen = Set<UUID>()
        var steps: [(name: AIUseStep, step: ExportStep)] = []
        for ref in statements.flatMap(\.sources) where seen.insert(ref.stepID).inserted {
            guard let step = snapshot.step(ref), let attempt = ordinal[ref.attemptID] else { continue }
            steps.append((AIUseStep(attempt: attempt, index: step.index), step))
        }
        steps.sort { $0.name < $1.name }
        facts.steps = steps.map(\.name)

        facts.statedByModel = statements.filter { $0.author.isModel }.map(\.label)
        var drafters = Set<ExportActor>()
        for (name, step) in steps {
            switch step.drafter {
            case .person: facts.draftedByPerson.append(name)
            case .model: facts.draftedByModel.append(name); drafters.insert(step.drafter)
            case .unknown: facts.draftedByUnknown.append(name)
            }
            let revisers = step.revisers
            if revisers.contains(.person) { facts.revisedByPerson.append(name) }
            if revisers.contains(where: \.isModel) { facts.revisedByModel.append(name) }
            if revisers.contains(.unknown) { facts.revisedByUnknown.append(name) }
            switch step.standing.human {
            case .checked: facts.checked.append(name)
            case .objected: facts.objected.append(name)
            case .unchecked: facts.unreviewed.append(name)
            }
            if step.standing.recheck != nil { facts.flagged.append(name) }
            for citation in step.citations {
                switch citation.status {
                case .found:
                    facts.citationsFound += 1
                    if let index = citation.indexName, !facts.foundIn.contains(index) { facts.foundIn.append(index) }
                case .notFound: facts.citationsNotFound += 1
                case .unverified: facts.citationsUnchecked += 1
                }
            }
        }
        facts.draftingModels = drafters.count

        for attempt in attempts {
            guard let number = ordinal[attempt.id] else { continue }
            if attempt.isPartial { facts.partialAttempts.append(number) }
            if let referee = Self.referee(of: attempt, number: number, exported: Set(steps.map(\.step.id))) {
                facts.referees.append(referee)
            }
        }

        let labels = Dictionary(statements.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        for statement in statements {
            let refuted = statement.derived.own == .refuted
            if refuted { facts.refuted.append(statement.label) }
            if let lean = statement.lean {
                facts.lean.append(LeanCheck(label: statement.label, standing: lean.standing, codeAuthor: lean.codeAuthor,
                                            modelDrafted: lean.modelDrafted))
            } else if !refuted {
                facts.notInLean.append(statement.label)
            }
            for run in statement.evidence {
                if run.reported {
                    facts.computations.append(Computation(label: statement.label, tool: run.tool, scope: run.scope,
                                                          verdict: run.verdict, codeAuthor: run.codeAuthor,
                                                          statementRefuted: refuted))
                } else {
                    facts.unfinishedRuns += 1
                }
            }
            if let source = statement.importedSource {
                facts.imported.append(Imported(
                    label: statement.label, source: source,
                    assumedBy: statements.filter { $0.derived.assumes.contains(statement.id) }.compactMap { labels[$0.id] },
                    verifiedInLean: statement.lean?.standing == .verified))
            }
        }

        facts.otherModelMessages = snapshot.modelMessages.filter { $0.map { !attemptIDs.contains($0) } ?? true }.count
        return facts
    }

    /// The standing verdict on `attempt`, over the exported steps: nil when no referee judged it.
    private static func referee(of attempt: ExportAttempt, number: Int, exported: Set<UUID>) -> Referee? {
        let checks = attempt.steps.map { (step: $0, check: $0.standing.model) }
        guard checks.contains(where: { $0.check != .noVerdict }) else { return nil }
        let refereeID = checks.lazy.compactMap(\.check.referee).first
        let name = { (step: ExportStep) in AIUseStep(attempt: number, index: step.index) }
        let drafterWasReferee = refereeID.map { attempt.author == .model(ModelSlotID($0)) } ?? false
        let shown = checks.filter { exported.contains($0.step.id) }

        let gaps = checks.filter { if case .gapListed = $0.check { true } else { false } }
        if !gaps.isEmpty || checks.contains(where: { if case .attemptHasGap = $0.check { true } else { false } }) {
            return Referee(attempt: number, drafterWasReferee: drafterWasReferee,
                           verdict: .gap(at: gaps.map { name($0.step) },
                                         outsideExport: gaps.contains { !exported.contains($0.step.id) }))
        }
        if checks.contains(where: { if case .unknownBasis = $0.check { true } else { false } }) {
            return Referee(attempt: number, drafterWasReferee: drafterWasReferee, verdict: .unknownBasis)
        }
        return Referee(attempt: number, drafterWasReferee: drafterWasReferee,
                       verdict: .complete(covered: shown.filter { $0.check.passes }.map { name($0.step) },
                                          revisedSince: shown.filter { !$0.check.passes }.map { name($0.step) }))
    }
}
