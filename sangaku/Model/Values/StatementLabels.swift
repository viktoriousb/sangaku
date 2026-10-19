import Foundation

nonisolated extension StatementKind {
    /// The start of a label: "Thm 1", "Lem 3", "Claim 2", "Conj".
    var labelPrefix: String {
        switch self {
        case .theorem: "Thm"
        case .lemma: "Lem"
        case .claim: "Claim"
        case .conjecture: "Conj"
        }
    }

    /// The kind as a heading word: "Lemma 3."
    var word: String {
        switch self {
        case .theorem: "Theorem"
        case .lemma: "Lemma"
        case .claim: "Claim"
        case .conjecture: "Conjecture"
        }
    }
}

/// Labels of statements. Labels are unique within a problem (compared trimmed and ignoring case), since the graph,
/// the context and exports name statements by label.
nonisolated enum StatementLabels {
    /// The next free label of a kind: one more than the highest number in use, so a number is never reused while
    /// a later one exists. A bare prefix ("Claim") counts as 1.
    static func next(for kind: StatementKind, existing: [String]) -> String {
        let prefix = kind.labelPrefix
        var highest = 0
        for label in existing {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.caseInsensitiveCompare(prefix) == .orderedSame {
                highest = max(highest, 1)
            } else if trimmed.lowercased().hasPrefix(prefix.lowercased() + " "),
                      let number = Int(trimmed.dropFirst(prefix.count + 1)), number > 0 {
                highest = max(highest, number)
            }
        }
        return "\(prefix) \(highest < Int.max ? highest + 1 : highest)"
    }

    /// The label as a heading: "Lem 3" of a lemma reads "Lemma 3"; any other label is kept.
    static func heading(_ label: String, kind: StatementKind) -> String {
        let prefix = kind.labelPrefix + " "
        guard label.hasPrefix(prefix), kind.labelPrefix != kind.word else { return label }
        return kind.word + " " + label.dropFirst(prefix.count)
    }

    static func normalized(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isTaken(_ label: String, among labels: [String]) -> Bool {
        let wanted = normalized(label)
        return labels.contains { normalized($0) == wanted }
    }

    /// Step numbers as ranges: `[1, 3, 4, 5]` gives "1, 3–5".
    static func rangeText(_ indices: [Int]) -> String {
        var runs: [(first: Int, last: Int)] = []
        for index in Set(indices).sorted() {
            if let run = runs.last, run.last < Int.max, index == run.last + 1 {
                runs[runs.count - 1].last = index
            } else {
                runs.append((index, index))
            }
        }
        return runs.map { $0.first == $0.last ? "\($0.first)" : "\($0.first)–\($0.last)" }.joined(separator: ", ")
    }
}
