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

nonisolated enum BranchState: String, StoredEnum {
    case live, adopted, running, deadEnd, parked
    static let fallback = BranchState.live
}

/// `reply` is a model's prose answer in the conversation; `attempt` is a structured attempt in a fan-out.
nonisolated enum MessageKind: String, StoredEnum {
    case prompt, reply, attempt, referee, compute, system
    static let fallback = MessageKind.system

    /// The role a model wrote this kind of message in. Provenance reads this, not the slot's current role, so
    /// changing a slot's role never relabels what it already wrote.
    var authoringRole: SlotRole? {
        switch self {
        case .reply, .attempt: .prover
        case .referee: .referee
        case .prompt, .compute, .system: nil
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
}
