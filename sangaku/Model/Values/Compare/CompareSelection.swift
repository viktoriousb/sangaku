import Foundation

/// Two attempts in the order Compare shows them: `first` is "Attempt 1".
nonisolated struct ComparedPair: Hashable, Sendable {
    var first: UUID
    var second: UUID

    /// The order for a pair with nothing stored yet (`SideOrder`).
    static func oriented(_ x: UUID, _ y: UUID) -> ComparedPair {
        let order = SideOrder.orient(x, y)
        return ComparedPair(first: order.first, second: order.second)
    }
}

/// Where Compare was asked to open: the attempts of a fan-out or referee message.
nonisolated struct CompareTarget: Hashable, Sendable {
    var attemptIDs: [UUID]
}

/// Which two attempts one window's Compare shows. The current row and the filter are kept apart
/// (`WindowState.compareRow`, `compareFilter`), so moving between rows or filtering does not choose them again.
nonisolated struct CompareSelection: Hashable, Sendable {
    /// Two attempts picked by hand, in either order; empty means "choose by `ComparePairChoice`".
    var picked: [UUID] = []
    /// The attempts of the message Compare was opened from.
    var candidateAttemptIDs: [UUID] = []
}

nonisolated enum ComparePairChoice {
    /// The two attempts picked by hand while both are offered; else the first two the entry point named; else the
    /// first two of the latest fan-out with two or more attempts; else the two newest attempts. Nil with fewer than two.
    static func resolve(_ selection: CompareSelection, among options: [AttemptOption]) -> (UUID, UUID)? {
        let offered = options.map(\.id)
        func firstTwo(_ ids: [UUID]) -> (UUID, UUID)? {
            let present = ids.filter(offered.contains).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
            return present.count >= 2 ? (present[0], present[1]) : nil
        }
        if let picked = firstTwo(selection.picked) { return picked }
        if let named = firstTwo(selection.candidateAttemptIDs) { return named }
        let byFanOut = Dictionary(grouping: options.filter { $0.fanOutID != nil }, by: { $0.fanOutID! })
        let latest = byFanOut.values.filter { $0.count >= 2 }
            .max { ($0.map(\.createdAt).max() ?? .distantPast) < ($1.map(\.createdAt).max() ?? .distantPast) }
        if let latest, let pair = firstTwo(latest.sorted(by: AttemptOption.precedes).map(\.id)) { return pair }
        return firstTwo(options.sorted { AttemptOption.precedes($1, $0) }.map(\.id))
    }
}

/// Which slot aligns two attempts: the referee of the fan-out both belong to, else the only referee-role slot, else
/// the person chooses among them. A slot that wrote either attempt never judges it.
nonisolated enum AlignerChoice: Hashable, Sendable {
    case slot(UUID)
    case choose([UUID])
    case none

    static func resolve(sharedFanOutReferee: UUID?, refereeSlots: [UUID], authors: Set<UUID>) -> AlignerChoice {
        let eligible = refereeSlots.filter { !authors.contains($0) }
        if let referee = sharedFanOutReferee, eligible.contains(referee) { return .slot(referee) }
        switch eligible.count {
        case 0: return .none
        case 1: return .slot(eligible[0])
        default: return .choose(eligible)
        }
    }
}

/// Four columns where they fit, else one card per row.
nonisolated enum CompareLayoutMode: Hashable, Sendable {
    case table, stacked

    /// The narrowest content width the four columns are drawn at.
    static let tableMinimumWidth: Double = 680

    static func resolve(width: Double) -> CompareLayoutMode {
        width >= tableMinimumWidth ? .table : .stacked
    }
}

/// Runs of an attempt's steps that match the other attempt, shown collapsed in the thread ("Steps 1–4 match A's").
nonisolated struct MatchedRuns: Hashable, Sendable {
    var runs: [ClosedRange<Int>]
    /// The letter of the attempt they match.
    var other: String
}

/// What the thread shows from a stored comparison: runs of steps that match the other attempt, which collapse, and
/// whether the attempts diverge. Only rows judged equivalent on the text the steps have now can collapse.
nonisolated enum ThreadAgreement {
    nonisolated enum Side: Hashable, Sendable { case first, second }

    /// Runs of two or more consecutive step numbers on `side` whose rows are equivalent now. A step in `keepOpen`
    /// (one a referee listed as a gap, a delicate step or a guess, or one with an open objection or a re-check flag)
    /// never collapses: it ends the run.
    static func collapsedRuns(_ rows: [CompareRow], side: Side, keepOpen: Set<Int> = []) -> [ClosedRange<Int>] {
        let matching = Set(rows.filter { $0.state == .equivalent }.compactMap { (side == .first ? $0.a : $0.b)?.index })
            .subtracting(keepOpen)
        var runs: [ClosedRange<Int>] = []
        for index in matching.sorted() {
            if let last = runs.last, last.upperBound == index - 1 {
                runs[runs.count - 1] = last.lowerBound...index
            } else {
                runs.append(index...index)
            }
        }
        return runs.filter { $0.count >= 2 }
    }

    /// The first row judged to diverge on the current text, in reading order.
    static func firstDivergence(_ rows: [CompareRow]) -> CompareRow? {
        rows.first { $0.state == .diverge }
    }
}

/// The row list's keys: J and K move between rows while the list has the keyboard, never while typing (`ListKeys`).
nonisolated enum CompareKeys {
    static let legend = "J / K between rows"
}
