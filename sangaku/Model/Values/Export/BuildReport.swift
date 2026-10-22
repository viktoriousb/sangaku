import Foundation

/// What the kit's `build.sh` reported, read from its output. It passes only if the script exited 0, LaTeX reported no
/// error, undefined reference, label defined twice or unresolved link, and every check the script runs printed PASS.
/// A line that is missing counts as not passed.
nonisolated struct BuildReport: Hashable, Sendable {
    nonisolated struct Counts: Hashable, Sendable {
        var errors: Int
        var undefined: Int
        var twice: Int
        var unresolved: Int
        var overfull: Int
        var pages: Int?
    }

    /// The checks `build.sh` prints, each as it begins.
    static let checks = ["tags", "frozen files unchanged", "every reference is defined", "no label is defined twice",
                         "every item has a label", "every item lies in a subsection"]

    var exitedCleanly: Bool
    var counts: Counts?
    var passed: [String]
    var failed: [String]
    /// The script's output, for the report.
    var output: String

    var missing: [String] {
        Self.checks.filter { check in !passed.contains { $0.hasPrefix(check) } && !failed.contains { $0.hasPrefix(check) } }
    }

    var isPass: Bool {
        guard exitedCleanly, let counts, failed.isEmpty, missing.isEmpty else { return false }
        return counts.errors == 0 && counts.undefined == 0 && counts.twice == 0 && counts.unresolved == 0
    }

    static func read(_ output: String, exitedCleanly: Bool) -> BuildReport {
        var report = BuildReport(exitedCleanly: exitedCleanly, counts: nil, passed: [], failed: [], output: output)
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("PASS ") { report.passed.append(String(line.dropFirst(5))) }
            if line.hasPrefix("FAIL ") { report.failed.append(String(line.dropFirst(5))) }
            if line.hasPrefix("LaTeX: ") { report.counts = counts(line) }
        }
        return report
    }

    /// "LaTeX: 0 errors, 0 undefined references, 0 labels defined twice, 0 unresolved links, 2 overfull boxes, 7 pages".
    private static func counts(_ line: String) -> Counts? {
        /// The number written just before `words`: "no pages" gives nil, never an earlier count.
        func number(before words: String) -> Int? {
            guard let range = line.range(of: " " + words) else { return nil }
            return Int(line[..<range.lowerBound].split(separator: " ").last ?? "")
        }
        guard let errors = number(before: "error"), let undefined = number(before: "undefined reference"),
              let twice = number(before: "label"), let unresolved = number(before: "unresolved link"),
              let overfull = number(before: "overfull box") else { return nil }
        return Counts(errors: errors, undefined: undefined, twice: twice, unresolved: unresolved, overfull: overfull,
                      pages: number(before: "page"))
    }

    /// The output with each statement's label (`lem:s1a2b3c4d5e6f`) followed by its name in the app.
    static func annotated(_ output: String, names: [String: String]) -> String {
        output.replacing(/(thm|lem|clm|conj|cex|ss):s([0-9a-f]{12})/) { match in
            let name = names[String(match.output.2)]
            return String(match.output.0) + (name.map { " (\($0))" } ?? "")
        }
    }
}
