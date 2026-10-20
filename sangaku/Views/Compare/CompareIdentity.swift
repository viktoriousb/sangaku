import Foundation

/// Who is who in a comparison, as Compare may show it: each side's author, the slots that may align, the referee a
/// row is sent to, and how they are named. Built once per render from whether the authors are hidden, and the only
/// way identity reaches any view of Compare. While hidden (invariant 9) it holds no author, no letter, no colour and
/// no directory to look one up in; the aligners are "the referee" or "Referee 2"; and text a model or provider wrote
/// is withheld when it may name one (`BlindShield`).
struct CompareIdentity: Equatable {
    /// The authors are hidden: blind mode is on and no verdict is recorded for this comparison.
    let hidden: Bool
    /// Side 1 and side 2; nil while hidden.
    let first: AuthorDirectory.AuthorMark?
    let second: AuthorDirectory.AuthorMark?
    /// The slot that wrote each side, for a repair request; nil while hidden or when a person wrote it.
    let firstSlotID: UUID?
    let secondSlotID: UUID?
    /// The slots that may align the attempts, by the name they may be shown under.
    let aligners: [UUID: String]
    /// Where a row is sent for judgement; nil while hidden, since asking names the model.
    let referee: CompareReferee?
    /// Model letters and names, to withhold model-written text that names them while hidden.
    let vocabulary: BlindShield.Vocabulary
    /// Names, once the authors may be shown; nil while hidden, so nothing here can look one up.
    private let authors: AuthorDirectory?

    static let withheldNote = "Note hidden while blind: it may name an author."

    static func make(hidden: Bool, first: Author?, second: Author?, choice: AlignerChoice,
                     authors: AuthorDirectory) -> CompareIdentity {
        let vocabulary = BlindShield.Vocabulary(
            letters: authors.slots.values.map(\.letter),
            names: authors.slots.values.map(\.modelName) + authors.catalog.models.map(\.id) + ["Anthropic", "Claude"])
        let ids = choice.slotIDs
        if hidden {
            let aligners = Dictionary(ids.enumerated().map { index, id in
                (id, ids.count == 1 ? "the referee" : "Referee \(index + 1)")
            }, uniquingKeysWith: { first, _ in first })
            return CompareIdentity(hidden: true, first: nil, second: nil, firstSlotID: nil, secondSlotID: nil,
                                   aligners: aligners, referee: nil, vocabulary: vocabulary, authors: nil)
        }
        func slot(_ author: Author?) -> UUID? {
            if case .model(let id) = author { return id.rawValue }
            return nil
        }
        func name(_ id: UUID) -> String { authors.name(of: .model(ModelSlotID(id))) }
        return CompareIdentity(
            hidden: false, first: authors.mark(of: first), second: authors.mark(of: second), firstSlotID: slot(first),
            secondSlotID: slot(second),
            aligners: Dictionary(ids.map { ($0, name($0)) }, uniquingKeysWith: { first, _ in first }),
            referee: ids.first.map { CompareReferee(id: $0, name: name($0)) }, vocabulary: vocabulary, authors: authors)
    }

    func mark(_ side: Int) -> AuthorDirectory.AuthorMark? { side == 1 ? first : second }

    /// "Attempt 1", or "Attempt 1 · Model A" once the authors may be shown.
    func title(_ side: Int) -> String {
        mark(side).map { "\(CompareWording.attempt(side)) · \($0.name)" } ?? CompareWording.attempt(side)
    }

    /// The slot that aligned the comparison: by name once the authors may be shown, "the referee" while hidden.
    func alignerName(_ slot: UUID?) -> String {
        guard let authors, let slot else { return "the referee" }
        return authors.name(of: .model(ModelSlotID(slot)))
    }

    /// An attempt in the pickers: author, time, steps and whether it is partial. The pickers are not shown while
    /// hidden; were they, they would name no author.
    func attemptLabel(_ option: AttemptOption) -> String {
        [authors?.name(of: option.author) ?? "Attempt", ShortTime.text(option.createdAt),
         Prose.count(option.stepCount, "step"), option.isPartial ? "partial" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Text a model or provider wrote, or `withheld` in its place while hidden if it may name an author.
    func shielded(_ text: String?, withheld: String = Self.withheldNote) -> String? {
        guard let text else { return nil }
        return !hidden || BlindShield.isSafe(text, vocabulary) ? text : withheld
    }

    /// A row's label, which the aligner wrote. While hidden, a label that may name an author gives way to what a
    /// step of the row establishes.
    func label(_ row: CompareRow) -> String {
        let candidates = [row.label, row.a?.establishes, row.b?.establishes].compactMap { $0 }.filter { !$0.isEmpty }
        guard hidden else { return candidates.first ?? "Row" }
        return candidates.first { BlindShield.isSafe($0, vocabulary) } ?? "Label hidden while blind"
    }

    /// Why aligning cannot be sent now, in words that name no model, letter or provider while hidden.
    func reason(_ blocker: SendBlocker) -> String {
        guard hidden else { return blocker.message }
        let words = switch blocker {
        case .missingKey: "No API key is stored for the aligner's provider."
        case .providerNotAllowed: "This problem does not allow the aligner's provider."
        case .noProvider: "The aligner's provider is not available."
        case .slotCannotReceive: "The aligner cannot take this request."
        case .recipient(_, let error): error.message
        default: blocker.message
        }
        return shielded(words, withheld: "Aligning cannot be sent now. The reason names a model: turn blind mode off to read it.")
            ?? words
    }
}

extension CompareIdentity {
    /// The identity Compare shows for two attempts of `problem`, `state` being their comparison: hidden while the
    /// window is blind and no verdict, readable or not, is stored for them. `CompareBranch` builds it this way only.
    static func read(_ state: ComparisonState, of x: ProofAttempt, _ y: ProofAttempt, in problem: Problem,
                     windowBlind: Bool, choice: AlignerChoice, people: [Person], catalog: ModelCatalog) -> CompareIdentity {
        let stored = problem.alignment(between: x.stableID, and: y.stableID)
        let (first, second) = state.first.id == x.stableID ? (x, y) : (y, x)
        return make(hidden: CompareBlind.hides(windowBlind: windowBlind, verdictRecorded: stored?.holdsRaw != nil),
                    first: first.message?.author, second: second.message?.author, choice: choice,
                    authors: AuthorDirectory(problem: problem, people: people, catalog: catalog))
    }
}

/// The slot a row is sent to for judgement, with its name.
struct CompareReferee: Equatable {
    let id: UUID
    let name: String
}

/// Where the comparison stands: the latest alignment request and the blind verdict. Read once per render, with
/// everything a model or provider wrote already shielded.
struct CompareRunInfo {
    /// The alignment request still running, by its record's stable ID.
    var aligningRecordID: UUID?
    /// The request whose answer the comparison holds.
    var alignedRecord: RequestRecord?
    /// The last request, when it stored nothing: why, in words.
    var lastProblem: String?
    var summary = ""
    /// A verdict is stored, whether or not this version can read it: it reveals the authors either way.
    var holdsRecorded = false
    var holds: HoldsVerdict?
    var holdsAt: Date?
    var alignerName = "the referee"

    static func read(_ stored: Alignment?, live: [UUID: MessageStream], identity: CompareIdentity) -> CompareRunInfo {
        let records = (stored?.requests ?? []).sorted {
            ($0.createdAt, $0.stableID.uuidString) < ($1.createdAt, $1.stableID.uuidString)
        }
        var info = CompareRunInfo()
        info.aligningRecordID = records.last { live[$0.stableID] != nil }?.stableID
        info.alignedRecord = records.first { $0.stableID == stored?.modelRunID }
        if let last = records.last, info.aligningRecordID == nil, last.finishedAt != nil,
           last.stableID != stored?.modelRunID {
            info.lastProblem = identity.shielded(CompareWording.storedNothing(last.outcome),
                                                 withheld: CompareWording.storedNothingWithheld)
        }
        info.summary = identity.shielded(stored?.modelSummary) ?? ""
        info.holdsRecorded = stored?.holdsRaw != nil
        info.holds = stored?.holds
        info.holdsAt = stored?.holdsAt
        info.alignerName = identity.alignerName(stored?.alignerSlotID)
        return info
    }
}
