import Foundation

/// "n of m steps checked by a person", over any set of steps: an attempt, or a statement's source steps. `checked`
/// is exactly status rule 3's per-step test, so "all steps checked" is said only when it is true (invariant 8).
nonisolated struct ReviewProgress: Hashable, Sendable {
    var total: Int
    var checked: Int
    /// Checked steps flagged for re-check (they still count as checked).
    var flagged: Int
    var withOpenObjections: Int

    init(_ standings: [StepStanding]) {
        total = standings.count
        checked = standings.filter(\.countsAsChecked).count
        flagged = standings.filter { $0.recheck != nil }.count
        withOpenObjections = standings.filter { $0.human == .objected }.count
    }

    var isComplete: Bool { total > 0 && checked == total }

    var headline: String {
        total == 0 ? "No steps" : "\(checked) of \(Prose.count(total, "step")) checked by a person"
    }

    var notes: [String] {
        var notes: [String] = []
        if withOpenObjections > 0 { notes.append("\(withOpenObjections) with an open objection") }
        if flagged > 0 { notes.append("\(flagged) flagged for re-check") }
        return notes
    }

}
