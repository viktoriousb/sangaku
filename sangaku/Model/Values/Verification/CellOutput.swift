import Foundation

/// What a computation's own code said about the claim: the last line of its output, if it is a result line. A model
/// wrote the code, so this is a report to read, never a proof; only a person's acceptance refutes a statement.
nonisolated enum CellOutputReader {
    static let prefix = "sangaku-result:"

    /// The verdict, and what followed it on the line (the counterexample, or why it is inconclusive).
    static func read(_ stdout: String) -> (verdict: CellVerdict, detail: String) {
        guard let last = stdout.split(whereSeparator: \.isNewline).last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return (.inconclusive, "") }
        let line = last.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(prefix) else { return (.inconclusive, "") }
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        for verdict in [CellVerdict.holds, .counterexample, .inconclusive] where rest.hasPrefix(verdict.rawValue) {
            let detail = rest.dropFirst(verdict.rawValue.count).trimmingCharacters(in: .whitespaces)
            // "holds" with anything after it is not a clean report.
            if verdict == .holds, !detail.isEmpty { return (.inconclusive, detail) }
            return (verdict, detail)
        }
        return (.inconclusive, "")
    }
}

/// Where a computation cell stands: waiting for a person's Run, running, or as its latest run ended.
nonisolated enum CellState: Hashable, Sendable {
    case waiting
    case running
    case ran(outcome: RunOutcome, verdict: CellVerdict)
}
