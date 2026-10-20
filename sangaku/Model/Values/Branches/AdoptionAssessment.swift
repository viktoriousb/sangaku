import Foundation

/// What a person should know before adopting an attempt. Adopting is allowed despite each, once acknowledged; none
/// of them is changed by adopting, since adopting checks nothing.
nonisolated enum AdoptionWarning: Hashable, Sendable {
    /// The attempt stopped before it finished.
    case partial
    /// No referee verdict covers the attempt's current text.
    case unrefereed
    /// The standing verdict found a gap.
    case gap(steps: [Int])
    /// Steps revised after the referee was asked: its verdict does not cover them.
    case revisedSinceReferee(steps: [Int])

    var message: String {
        switch self {
        case .partial: "This attempt stopped before it finished."
        case .unrefereed: "No referee verdict covers this attempt's current text."
        case .gap(let steps) where steps.isEmpty: "A referee found a gap in this attempt."
        case .gap(let steps): "A referee found a gap at \(Self.steps(steps))."
        case .revisedSinceReferee(let steps): "\(Self.steps(steps).capitalizedFirst) changed after the referee judged the attempt."
        }
    }

    private static func steps(_ indices: [Int]) -> String {
        (indices.count == 1 ? "step " : "steps ") + Prose.list(indices.map(String.init))
    }

    /// The warnings for an attempt from its steps' standings (rule 4) and whether it stopped early.
    static func warnings(standings: [StepStanding], partial: Bool) -> [AdoptionWarning] {
        var unrefereed = standings.isEmpty, gap = false
        var gapSteps: [Int] = [], revised: [Int] = []
        for standing in standings.sorted(by: { $0.index < $1.index }) {
            switch standing.model {
            case .noVerdict, .unknownBasis: unrefereed = true
            case .gapListed:
                gap = true
                gapSteps.append(standing.index)
            case .attemptHasGap: gap = true
            case .revisedSince: revised.append(standing.index)
            case .complete: break
            }
        }
        var warnings: [AdoptionWarning] = partial ? [.partial] : []
        if unrefereed { warnings.append(.unrefereed) }
        if gap { warnings.append(.gap(steps: gapSteps)) }
        if !revised.isEmpty { warnings.append(.revisedSinceReferee(steps: revised)) }
        return warnings
    }
}

/// Everything the Adopt sheet shows, and whether adopting would be refused. `BranchManager.adopt` and the sheet use
/// the same assessment, so they cannot disagree.
nonisolated struct AdoptionAssessment: Hashable, Sendable {
    var attemptID: UUID
    /// The branch the attempt was written on: it becomes the main line.
    var branchID: UUID
    var branchName: String
    var branchIsMain: Bool
    var stepCount: Int
    var warnings: [AdoptionWarning]
    var progress: ReviewProgress
    /// Why adopting would be refused now, or nil.
    var refusal: BranchError?
}

private extension String {
    nonisolated var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
