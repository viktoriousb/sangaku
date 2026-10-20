import Foundation
import SwiftData

/// The comparisons of a problem's attempts. The only writer of a person's corrections and blind verdicts; a model's
/// alignment rows are written by `ThreadManager`, which owns the request. A person's writes are in the name of the
/// person using the app: no parameter names one. Nothing here changes a review, a check or a status; a comparison is
/// never trust (invariant 1). Comparisons are never sent to models, so a write schedules a save and nothing more.
@Observable
final class AlignmentService {
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let saves: SaveScheduler
    @ObservationIgnored let problems: ProblemManager
    @ObservationIgnored private let now: () -> Date

    init(context: ModelContext, saves: SaveScheduler, problems: ProblemManager, now: @escaping () -> Date = { .now }) {
        self.context = context
        self.saves = saves
        self.problems = problems
        self.now = now
    }

    /// The comparison of two attempts as Compare shows it, read fresh. Nil unless they are two attempts of one problem.
    func comparison(of x: ProofAttempt, _ y: ProofAttempt, people: Set<UUID>? = nil) -> ComparisonState? {
        guard x.stableID != y.stableID, let problem = x.message?.branch?.problem,
              problem.stableID == y.message?.branch?.problem?.stableID else { return nil }
        return ComparisonState.read(x, y, in: problem, people: people ?? problems.personIDs())
    }

    // MARK: A person's corrections

    /// Pairs two steps, one of each attempt, taking each out of the row it was in.
    func pair(_ key: RowKey, in pair: ComparedPair) throws(CompareError) {
        let (state, steps) = try current(pair, key)
        guard state[row: steps] == nil else { return }
        try record(.pair, steps, in: pair)
    }

    /// Separates two paired steps; each then stands alone unless paired again by hand.
    func unpair(_ key: RowKey, in pair: ComparedPair) throws(CompareError) {
        let (state, steps) = try current(pair, key)
        guard state[row: steps] != nil else { throw .notPaired }
        try record(.unpair, steps, in: pair)
    }

    /// Judges a pair equivalent or diverging, on the revisions the person read: refused if either step changed since,
    /// or has no recorded revision for the judgement to cover.
    func judge(_ verdict: AlignmentVerdict, _ key: RowKey, seen: RowKey, in pair: ComparedPair) throws(CompareError) {
        let (state, steps) = try current(pair, key)
        guard let row = state[row: steps], let a = row.a, let b = row.b else { throw .notPaired }
        guard a.revisionID != nil, b.revisionID != nil else { throw .noRevision }
        let seen = steps == key ? seen : RowKey(a: seen.b, b: seen.a)
        guard a.revisionID == seen.a, b.revisionID == seen.b else { throw .staleRevision }
        try record(.judge, steps, verdict: verdict == .equivalent ? .equivalent : .diverge,
                   revisions: RowKey(a: a.revisionID, b: b.revisionID), in: pair)
    }

    /// Withdraws the person's judgement of a pair, returning it to the model's verdict, if any.
    func clearJudgement(_ key: RowKey, in pair: ComparedPair) throws(CompareError) {
        let (state, steps) = try current(pair, key)
        guard state[row: steps]?.judgedBy == .person else { return }
        try record(.clear, steps, in: pair)
    }

    // MARK: The blind verdict

    /// Records which attempt holds up. Recording it reveals the authors of this comparison (invariant 9); it is
    /// recorded once, and changes no review, check or status. A stored verdict this version cannot read counts as
    /// recorded too, and is never written over.
    func recordHolds(_ verdict: HoldsVerdict, in pair: ComparedPair) throws(CompareError) {
        let (_, _, problem) = try attempts(pair)
        guard problem.alignment(between: pair.first, and: pair.second)?.holdsRaw == nil else {
            throw .verdictAlreadyRecorded
        }
        let stored = problem.alignment(for: pair, creatingIn: context, at: now())
        stored.holdsRaw = verdict.rawValue
        stored.holdsByID = problems.me().stableID
        stored.holdsAt = now()
        saves.markDirty()
    }

    // MARK: Helpers

    private func attempts(_ pair: ComparedPair) throws(CompareError) -> (ProofAttempt, ProofAttempt, Problem) {
        guard pair.first != pair.second else { throw .notAPair }
        guard let first = attempt(pair.first), let second = attempt(pair.second) else { throw .noSuchAttempt }
        guard let problem = first.message?.branch?.problem,
              problem.stableID == second.message?.branch?.problem?.stableID else { throw .notAPair }
        return (first, second, problem)
    }

    /// The comparison as it stands, and the two steps as stored (side 1 first), whichever order they were given in.
    private func current(_ pair: ComparedPair, _ key: RowKey) throws(CompareError) -> (ComparisonState, RowKey) {
        let (first, second, problem) = try attempts(pair)
        let state = ComparisonState.read(first, second, in: problem, people: problems.personIDs())
        guard !state.correctionsUnreadable else { throw .correctionsUnreadable }
        let inFirst = Set(state.first.steps.map(\.id)), inSecond = Set(state.second.steps.map(\.id))
        if let a = key.a, let b = key.b, inFirst.contains(a), inSecond.contains(b) { return (state, key) }
        if let a = key.a, let b = key.b, inFirst.contains(b), inSecond.contains(a) { return (state, RowKey(a: b, b: a)) }
        throw .stepNotInAttempt
    }

    private func record(_ action: AlignmentCorrection.Action, _ steps: RowKey, verdict: AlignmentVerdict? = nil,
                        revisions: RowKey? = nil, in pair: ComparedPair) throws(CompareError) {
        guard let a = steps.a, let b = steps.b else { throw .stepNotInAttempt }
        let (_, _, problem) = try attempts(pair)
        let alignment = problem.alignment(for: pair, creatingIn: context, at: now())
        guard alignment.correctionsAreReadable else { throw .correctionsUnreadable }
        alignment.corrections += [AlignmentCorrection(
            action: action, stepAID: a, stepBID: b, verdict: verdict?.rawValue, revisionAID: revisions?.a,
            revisionBID: revisions?.b, personID: problems.me().stableID, at: now())]
        alignment.correctedByUser = true
        saves.markDirty()
    }

    private func attempt(_ id: UUID) -> ProofAttempt? {
        var descriptor = FetchDescriptor<ProofAttempt>(predicate: #Predicate { $0.stableID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
