import Foundation

// Reading what an export may say out of the store, with the readers the screens use, so an export never states more
// than the app shows. Called on the main actor; everything after it is pure.

extension ExportSnapshot {
    /// `people` holds the stable IDs of `Person` records: only they check, accept a refutation or confirm fidelity
    /// (invariant 1).
    static func read(problem: Problem, people: Set<UUID>) -> ExportSnapshot {
        read(problem: problem, people: people, graph: StatementGraphState.read(problem: problem, people: people),
             verification: VerificationState.read(problem: problem, people: people))
    }

    /// With the graph and verification state a screen has already read for the same people.
    static func read(problem: Problem, people: Set<UUID>, graph: StatementGraphState,
                     verification: VerificationState) -> ExportSnapshot {
        let messages = (problem.branches ?? []).flatMap { $0.messages ?? [] }
        let modelDrafted = Set(messages.filter { $0.author.map { !$0.isHuman } ?? false }.compactMap { $0.leanDraft?.statementID })
        let entities = Dictionary((problem.statements ?? []).map { ($0.stableID, $0) },
                                  uniquingKeysWith: { first, _ in first })

        var attempts: [UUID: ExportAttempt] = [:]
        for node in graph.nodes {
            for step in entities[node.id]?.sourceSteps ?? [] {
                let id = step.attempt?.stableID ?? step.stableID
                guard attempts[id] == nil else { continue }
                attempts[id] = step.attempt.map { ExportAttempt.read($0, people: people) }
                    ?? ExportAttempt.alone(step, people: people)
            }
        }

        let statements = graph.nodes.map { node in
            let sources = node.sources.map { ExportStepRef(attemptID: $0.attemptID ?? $0.stepID, stepID: $0.stepID) }
            let standings = sources.compactMap { attempts[$0.attemptID]?[step: $0.stepID]?.standing }
            let partial = Set(sources.map(\.attemptID)).contains { attempts[$0]?.isPartial == true }
            return ExportStatement(
                id: node.id, kind: node.kind, label: node.label, text: node.statementLaTeX, createdAt: node.createdAt,
                isPinned: node.isPinned,
                author: ExportActor(node.author), derived: node.derived, explanation: node.explanation,
                importedSource: node.importedSource, refutationNote: node.refutationNote, sources: sources,
                uses: node.uses,
                lean: verification.lean[node.id].flatMap {
                    ExportLean($0, moduleDigest: entities[node.id]?.leanResult?.moduleDigest ?? "",
                               modelDrafted: modelDrafted.contains(node.id))
                },
                evidence: (entities[node.id]?.evidence ?? []).sorted(by: Evidence.newestFirst).map(ExportEvidence.init),
                progress: ReviewProgress(standings, partial: partial))
        }

        let modelMessages = messages.filter { $0.author.map { !$0.isHuman } ?? false }.map { $0.proofAttempt?.stableID }

        let notation = NotationRegistry(entries: problem.sortedNotation)
        return ExportSnapshot(
            problemID: problem.stableID, title: problem.title, theoremID: graph.pinnedID, statements: statements,
            attempts: attempts.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) },
            modelMessages: modelMessages,
            notation: notation.rows.map { ExportNotation(symbol: $0.symbolLaTeX, meaning: $0.meaning) },
            macros: notation.macros)
    }
}

extension FormulaVerdicts {
    /// The app's renderer's verdict on every formula of the snapshot, with the problem's macros (invariant 16).
    static func read(_ snapshot: ExportSnapshot, renderer: MathRenderer) -> FormulaVerdicts {
        let context = MathContext(macros: snapshot.macros, fontSize: 16)
        return FormulaVerdicts(texts: snapshot.proseTexts) { latex, style in
            if case .source(let chip) = renderer.render(latex, context: context, style: style) { chip.message } else { nil }
        }
    }
}

extension ExportAttempt {
    static func read(_ attempt: ProofAttempt, people: Set<UUID>) -> ExportAttempt {
        let state = AttemptReviewState.read(attempt: attempt, people: people)
        let citations = Dictionary(grouping: CitationFact.read(attempt), by: \.stepID)
        return ExportAttempt(id: attempt.stableID, createdAt: attempt.message?.createdAt ?? .distantPast,
                             author: ExportActor(attempt.message?.author), isPartial: state.progress.partial,
                             steps: state.steps.map { ExportStep($0, citations: citations[$0.id] ?? []) })
    }

    /// A step whose attempt is gone stands alone, with no verdict.
    static func alone(_ step: Step, people: Set<UUID>) -> ExportAttempt {
        let state = AttemptReviewState(AttemptFact(id: step.stableID, steps: [step.fact]), people: people)
        return ExportAttempt(id: step.stableID, createdAt: .distantPast, author: .unknown, isPartial: false,
                             steps: state.steps.map { ExportStep($0, citations: []) })
    }
}

nonisolated extension ExportStep {
    init(_ review: StepReview, citations: [CitationFact]) {
        self.init(
            id: review.id, index: review.index, text: review.text, establishes: review.establishes,
            confidence: review.confidence,
            authors: review.provenance.versions.map { ExportActor($0.author) },
            standing: review.standing,
            citations: citations.map {
                ExportCitation(id: $0.id, text: $0.text, status: $0.status, link: $0.link, indexName: $0.indexName,
                               matchedTitle: $0.matchedTitle, matchedAuthors: $0.matchedAuthors,
                               matchedYear: $0.matchedYear)
            })
    }
}

nonisolated extension ExportLean {
    /// Nil for a statement never checked in Lean.
    init?(_ facts: LeanFacts, moduleDigest: String, modelDrafted: Bool) {
        guard facts.standing != .notChecked else { return nil }
        self.init(standing: facts.standing, codeAuthor: ExportActor(facts.sourceAuthor), checkedAt: facts.checkedAt,
                  leanVersion: facts.leanVersion, mathlibRev: facts.mathlibRev,
                  sorryCount: facts.sorryLocations.count, nonstandardAxioms: facts.nonstandardAxioms,
                  source: facts.source, moduleDigest: moduleDigest, modelDrafted: modelDrafted)
    }
}

extension ExportEvidence {
    init(_ evidence: Evidence) {
        self.init(id: evidence.stableID, tool: evidence.tool, toolVersion: evidence.toolVersion, scope: evidence.scope,
                  outcome: evidence.outcome, verdict: evidence.verdict,
                  codeAuthor: ExportActor(evidence.cell?.message?.author),
                  codeDigest: String(TextDigest(of: evidence.code).hex.prefix(12)), createdAt: evidence.createdAt)
    }
}
