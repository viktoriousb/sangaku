import Foundation
import SwiftData

// Reading a comparison out of the store as plain values. Called inside view bodies, so Observation tracks every
// property read here.

extension Problem {
    /// The stored comparison of two attempts, whichever order they are given in.
    func alignment(between x: UUID, and y: UUID) -> Alignment? {
        (alignments ?? []).first { Set([$0.attemptAID, $0.attemptBID]) == Set([x, y]) }
    }

    /// Two attempts in the order Compare shows them: as stored, or by `SideOrder` while nothing is stored. Whoever
    /// asks, and in whatever order they pass the attempts, gets the same "Attempt 1".
    func orientation(of x: UUID, _ y: UUID) -> ComparedPair {
        if let stored = alignment(between: x, and: y), let first = stored.attemptAID, let second = stored.attemptBID {
            return ComparedPair(first: first, second: second)
        }
        return .oriented(x, y)
    }

    /// The stored comparison of a pair, created with its sides fixed by `SideOrder` if there is none yet. The one
    /// place a comparison is created.
    func alignment(for pair: ComparedPair, creatingIn context: ModelContext, at date: Date) -> Alignment {
        if let stored = alignment(between: pair.first, and: pair.second) { return stored }
        let order = ComparedPair.oriented(pair.first, pair.second)
        let created = Alignment(attemptAID: order.first, attemptBID: order.second)
        created.createdAt = date
        context.insert(created)
        created.problem = self
        return created
    }
}

extension AlignedAttempt {
    /// An attempt's steps with their current revision's text, and whether a person's ✓ counts on each.
    init(_ attempt: ProofAttempt, people: Set<UUID>) {
        let standings = StepStandings.standings(of: attempt.sortedSteps, people: people)
        self.init(id: attempt.stableID, steps: attempt.sortedSteps.map { step in
            AlignedStep(id: step.stableID, index: step.index, establishes: step.currentEstablishes, text: step.currentText,
                        revisionID: step.latestRevision?.stableID,
                        countsAsChecked: standings[step.stableID]?.countsAsChecked ?? false)
        }, isPartial: attempt.message?.outcome(isStreaming: false).isPartial ?? false)
    }
}

extension ComparisonState {
    /// The comparison of two attempts of `problem`, in the order Compare shows them (`Problem.orientation`).
    static func read(_ x: ProofAttempt, _ y: ProofAttempt, in problem: Problem, people: Set<UUID>) -> ComparisonState {
        let stored = problem.alignment(between: x.stableID, and: y.stableID)
        let (first, second) = problem.orientation(of: x.stableID, y.stableID).first == x.stableID ? (x, y) : (y, x)
        return ComparisonState(ComparisonFacts(
            first: AlignedAttempt(first, people: people), second: AlignedAttempt(second, people: people),
            modelRows: stored?.rows, modelRowsUnreadable: !(stored?.rowsAreReadable ?? true),
            corrections: stored?.corrections ?? [], correctionsUnreadable: !(stored?.correctionsAreReadable ?? true)))
    }
}

extension AlignerChoice {
    /// Who may align two attempts of `problem`: the referee of the fan-out both belong to, else a referee-role slot
    /// that wrote neither.
    static func resolve(_ x: ProofAttempt, _ y: ProofAttempt, in problem: Problem) -> AlignerChoice {
        let shared = x.fanOut != nil && x.fanOut?.stableID == y.fanOut?.stableID ? x.fanOut?.refereeSlotID : nil
        let referees = problem.sortedModelSlots.filter { $0.role == .referee }.map(\.stableID)
        return resolve(sharedFanOutReferee: shared, refereeSlots: referees, authors: authorSlots(x, y))
    }

    /// The slots that wrote either attempt; a slot never aligns its own work.
    static func authorSlots(_ x: ProofAttempt, _ y: ProofAttempt) -> Set<UUID> {
        Set([x.message?.author, y.message?.author].compactMap { author -> UUID? in
            if case .model(let id)? = author { return id.rawValue }
            return nil
        })
    }

    /// The slots this choice offers, in order.
    var slotIDs: [UUID] {
        switch self {
        case .slot(let id): [id]
        case .choose(let ids): ids
        case .none: []
        }
    }
}
