import Foundation

/// "n of m steps checked by a person", over any set of steps: an attempt, or a statement's source steps. `checked`
/// is exactly status rule 3's per-step test, so "all steps checked" is said only when it is true (invariant 8). Steps
/// from an attempt that stopped before its end are said to be so, since checking every step that exists is not
/// checking a finished argument.
nonisolated struct ReviewProgress: Hashable, Sendable {
    var total: Int
    var checked: Int
    /// Checked steps flagged for re-check (they still count as checked).
    var flagged: Int
    var withOpenObjections: Int
    /// An attempt the steps come from stopped before its end.
    var partial: Bool

    static let partialClause = "the attempt stopped before its end"

    init(_ standings: [StepStanding], partial: Bool = false) {
        total = standings.count
        checked = standings.filter(\.countsAsChecked).count
        flagged = standings.filter { $0.recheck != nil }.count
        withOpenObjections = standings.filter { $0.human == .objected }.count
        self.partial = partial
    }

    /// Every step counts as checked: status rule 3's test, partial or not.
    var isComplete: Bool { total > 0 && checked == total }

    /// "All steps checked" may be said: every step is checked and the attempt finished.
    var claimsAll: Bool { isComplete && !partial }

    var headline: String {
        guard total > 0 else { return "No steps" }
        let base = "\(checked) of \(Prose.count(total, "step")) checked by a person"
        return partial ? base + "; " + Self.partialClause : base
    }

    var notes: [String] {
        var notes: [String] = []
        if withOpenObjections > 0 { notes.append("\(withOpenObjections) with an open objection") }
        if flagged > 0 { notes.append("\(flagged) flagged for re-check") }
        return notes
    }

}
