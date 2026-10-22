import Foundation

/// Who did something, as exports say it: a role, never a name (decided for 8b). Models are told apart only by their
/// slot, which no export prints.
nonisolated enum ExportActor: Hashable, Sendable {
    case person
    case model(ModelSlotID)
    /// The record names no author.
    case unknown

    init(_ author: Author?) {
        switch author {
        case .human: self = .person
        case .model(let slot): self = .model(slot)
        case nil: self = .unknown
        }
    }

    var isModel: Bool {
        if case .model = self { true } else { false }
    }
}

/// A citation of a step, as exports print it.
nonisolated struct ExportCitation: Hashable, Sendable, Identifiable {
    var id: UUID
    var text: String
    var status: CitationStatus
    /// Only for a found citation with an https link to an index (invariant 6).
    var link: URL?
    var indexName: String?
    var matchedTitle: String?
    var matchedAuthors: [String] = []
    var matchedYear: Int?
}

/// One step of an attempt: its current text, who wrote each version (invariant 7) and where it stands.
nonisolated struct ExportStep: Hashable, Sendable, Identifiable {
    var id: UUID
    var index: Int
    var text: String
    var establishes: String
    var confidence: Confidence
    /// Who wrote each version, oldest first.
    var authors: [ExportActor]
    var standing: StepStanding
    var citations: [ExportCitation] = []

    /// Who wrote the first version.
    var drafter: ExportActor { authors.first ?? .unknown }

    /// Who wrote the versions after the first, without repeats, in order.
    var revisers: [ExportActor] {
        var seen: [ExportActor] = []
        for author in authors.dropFirst() where !seen.contains(author) { seen.append(author) }
        return seen
    }
}

/// An attempt that one of the exported statements' steps come from. Every step is kept, since a step's standing
/// depends on the steps before it.
nonisolated struct ExportAttempt: Hashable, Sendable, Identifiable {
    var id: UUID
    var createdAt: Date
    var author: ExportActor
    /// The attempt stopped before its end.
    var isPartial: Bool
    /// In index order.
    var steps: [ExportStep]

    subscript(step id: UUID) -> ExportStep? { steps.first { $0.id == id } }
}

/// A source step of a statement.
nonisolated struct ExportStepRef: Hashable, Sendable {
    var attemptID: UUID
    var stepID: UUID
}

/// A statement's Lean check as exports state it. Only `standing == .verified` is rule 2 holding.
nonisolated struct ExportLean: Hashable, Sendable {
    var standing: LeanStanding
    var codeAuthor: ExportActor
    var checkedAt: Date?
    var leanVersion: String
    var mathlibRev: String
    var sorryCount: Int
    var nonstandardAxioms: [String]
    /// The checked code, when its two parts were kept: what the Lean project exports.
    var source: LeanSource?
    /// The digest of the module the check compiled.
    var moduleDigest: String = ""
    /// A language model drafted Lean code for the statement, whoever wrote the code that was checked.
    var modelDrafted = false
}

/// One run of a computation on a statement, cited by digest: exports never reproduce the code.
nonisolated struct ExportEvidence: Hashable, Sendable, Identifiable {
    var id: UUID
    var tool: EvidenceTool
    var toolVersion: String
    var scope: String
    var outcome: RunOutcome
    var verdict: CellVerdict
    var codeAuthor: ExportActor
    /// The first 12 hex digits of the code's SHA-256.
    var codeDigest: String
    var createdAt: Date

    /// Its code completed and reported a result: no counterexample, or one.
    var reported: Bool { outcome == .completed && verdict != .inconclusive }
}

/// One statement as exports state it: its words, its derived status and why, and where its proof comes from.
nonisolated struct ExportStatement: Hashable, Sendable, Identifiable {
    var id: UUID
    var kind: StatementKind
    var label: String
    var text: String
    var createdAt: Date
    var isPinned: Bool
    var author: ExportActor
    var derived: DerivedStatus
    var explanation: StatusExplanation
    var importedSource: String?
    var refutationNote: String?
    /// Ordered by attempt, then step.
    var sources: [ExportStepRef]
    /// In graph order.
    var uses: [UUID]
    /// Nil when it was never checked in Lean.
    var lean: ExportLean?
    /// Newest first.
    var evidence: [ExportEvidence]
    /// Over its source steps; partial when an attempt they come from stopped before its end.
    var progress: ReviewProgress
}

/// One row of the problem's notation.
nonisolated struct ExportNotation: Hashable, Sendable {
    var symbol: String
    var meaning: String
}

/// Which statements an export holds.
nonisolated enum ExportScope: Hashable, Sendable {
    /// The problem's theorem and everything it uses, directly or through other statements: the LaTeX export and
    /// Review's card.
    case theoremAndUses
    /// Every statement of the problem: the hashtag manuscript.
    case everyStatement
}

/// What an export may say about a problem, read on the main actor in one pass and then handed to pure code.
/// It holds no person's or model's name: only roles (`ExportActor`).
nonisolated struct ExportSnapshot: Hashable, Sendable {
    var problemID: UUID
    var title: String
    var theoremID: UUID?
    /// In graph order.
    var statements: [ExportStatement]
    /// Every attempt an exported step comes from, oldest first.
    var attempts: [ExportAttempt]
    /// One entry per message written by a language model: the attempt it carries, if any.
    var modelMessages: [UUID?] = []
    var notation: [ExportNotation] = []
    /// The notation's macros, as the renderer expands them.
    var macros: MacroSet = .empty

    var theorem: ExportStatement? { statements.first { $0.id == theoremID } }

    /// The statements of `scope`, in graph order.
    func statements(in scope: ExportScope) -> [ExportStatement] {
        switch scope {
        case .everyStatement:
            return statements
        case .theoremAndUses:
            guard let theoremID else { return [] }
            let uses = Dictionary(statements.map { ($0.id, $0.uses) }, uniquingKeysWith: { first, _ in first })
            var included: Set<UUID> = [theoremID]
            var stack = [theoremID]
            while let next = stack.popLast() {
                for dependency in uses[next] ?? [] where included.insert(dependency).inserted { stack.append(dependency) }
            }
            return statements.filter { included.contains($0.id) }
        }
    }

    /// The attempts the statements of `scope` rest on, oldest first: attempt 1 is the first of them.
    func attempts(in scope: ExportScope) -> [ExportAttempt] {
        let ids = Set(statements(in: scope).flatMap(\.sources).map(\.attemptID))
        return attempts.filter { ids.contains($0.id) }
    }

    /// Each attempt of `scope` by its number: the one numbering the proofs and the AI-use statement share.
    func attemptNumbers(in scope: ExportScope) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: attempts(in: scope).enumerated().map { ($1.id, $0 + 1) })
    }

    func attempt(_ id: UUID) -> ExportAttempt? { attempts.first { $0.id == id } }

    /// Every text an export may typeset, so the renderer's verdict on each of its formulas can be read first.
    var proseTexts: [String] {
        // The title is typeset on one line, so its formulas are read as they will be gated.
        var texts = [title, TeXGate.oneLine(title).trimmingCharacters(in: .whitespaces)]
        for statement in statements {
            texts.append(statement.text)
            if let note = statement.refutationNote { texts.append(note) }
            texts += statement.evidence.map(\.scope)
        }
        texts += attempts.flatMap { $0.steps.map(\.text) }
        texts += notation.flatMap { ["$" + $0.symbol + "$", $0.meaning] }
        return texts
    }

    func step(_ ref: ExportStepRef) -> ExportStep? { attempt(ref.attemptID)?[step: ref.stepID] }
}
