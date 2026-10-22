import Foundation

/// An enum persisted as its raw string. An unknown or missing value decodes to `fallback`, which is always the
/// least-trusting case (an unknown review verdict is `.unclear`, never `.correct`).
nonisolated protocol StoredEnum: RawRepresentable, CaseIterable, Codable, Hashable, Sendable where RawValue == String {
    static var fallback: Self { get }
}

nonisolated extension StoredEnum {
    init(stored raw: String?) {
        self = raw.flatMap(Self.init(rawValue:)) ?? .fallback
    }
}

nonisolated enum StatementKind: String, StoredEnum {
    case theorem, lemma, claim, conjecture
    static let fallback = StatementKind.claim
}

/// A branch's lifecycle, set by people only. Whether it is the main line (`Problem.mainBranchID`) and whether a
/// request runs on it (`ThreadManager.streamingBranchIDs`) are derived, never stored: the values "adopted" and
/// "running" of earlier versions read as `live`.
nonisolated enum BranchState: String, StoredEnum {
    case live, deadEnd, parked
    static let fallback = BranchState.live

    /// Retired: a dead end or parked. Nothing more is sent on it until it is reopened.
    var isClosed: Bool { self != .live }

    /// What follows "this branch is": "live", "a dead end", "parked".
    var phrase: String {
        switch self {
        case .live: "live"
        case .deadEnd: "a dead end"
        case .parked: "parked"
        }
    }
}

/// `reply` is a model's prose answer in the conversation; `attempt` is a structured attempt in a fan-out.
nonisolated enum MessageKind: String, StoredEnum {
    /// `refereeReply` is a referee's prose answer to a question (about one row of a comparison, say): never a
    /// verdict on an attempt, which only `referee` messages give.
    /// `leanDraft` is a formalizer's Lean code for a statement; `compute` carries a computation cell.
    case prompt, reply, attempt, referee, refereeReply, compute, leanDraft, system
    static let fallback = MessageKind.system

    /// The role a model wrote this kind of message in. Provenance reads this, not the slot's current role, so
    /// changing a slot's role never relabels what it already wrote.
    var authoringRole: SlotRole? {
        switch self {
        case .reply, .attempt: .prover
        case .referee, .refereeReply: .referee
        case .leanDraft: .formalizer
        case .compute: .scout
        case .prompt, .system: nil
        }
    }
}

/// How a structured output (an attempt's steps, a referee's verdicts) was read.
nonisolated enum ParseState: String, StoredEnum {
    /// Read whole, as the schema asks.
    case clean
    /// The request ended early; the parts that were complete were read, the rest is kept as raw output.
    case partial
    /// Nothing could be read as structure; the raw text is shown as written.
    case unstructured
    static let fallback = ParseState.unstructured
}

nonisolated enum SlotRole: String, StoredEnum {
    case prover, referee, formalizer, scout
    static let fallback = SlotRole.prover
}

nonisolated enum FanOutVisibility: String, StoredEnum {
    case independent, shared
    static let fallback = FanOutVisibility.independent
}

/// A model's own confidence label for a step. Displayed, never used to skip review (invariant 10).
nonisolated enum Confidence: String, StoredEnum {
    case standard, routine, delicate, guess
    static let fallback = Confidence.guess
}

nonisolated enum ReviewVerdict: String, StoredEnum {
    case correct, wrong, unclear
    static let fallback = ReviewVerdict.unclear
}

nonisolated enum RefereeOutcome: String, StoredEnum {
    case complete, gap
    static let fallback = RefereeOutcome.gap
}

nonisolated enum CitationStatus: String, StoredEnum {
    case unverified, found, notFound
    static let fallback = CitationStatus.unverified
}

nonisolated enum EvidenceTool: String, StoredEnum {
    case gap, sage, python
    static let fallback = EvidenceTool.python
}

/// How a run of a computation ended, as the runner saw it. The fallback is the least informative case.
nonisolated enum RunOutcome: String, StoredEnum {
    /// The process exited with status 0.
    case completed
    case exitedNonzero, timedOut, memoryLimit, diskLimit, stopped
    /// It started but ended without a readable exit, or could not be launched at all.
    case couldNotRun
    static let fallback = RunOutcome.couldNotRun
}

/// What a computation's own code reported (`CellOutputReader`): a report, never a proof.
nonisolated enum CellVerdict: String, StoredEnum {
    case holds, counterexample, inconclusive
    static let fallback = CellVerdict.inconclusive
}

nonisolated enum AlignmentVerdict: String, StoredEnum {
    case equivalent, diverge, onlyA, onlyB
    static let fallback = AlignmentVerdict.diverge
}

/// Whether a Lean statement says what the informal statement says, as judged by a person.
nonisolated enum FidelityVerdict: String, StoredEnum {
    case matches, differs
    static let fallback = FidelityVerdict.differs
}

/// Derived, never stored from model output (see `StatusRules`).
nonisolated enum StatementStatus: String, CaseIterable, Codable, Hashable, Sendable {
    case proposed, sketched, modelChecked, humanChecked, formallyVerified, refuted
    /// A result from the literature, marked so by a person: not proved or checked here. Outside the ladder, like
    /// refuted; what uses it is not lowered by it but says that it assumes it.
    case imported
}
