import Foundation

/// Code as it will run, checked for characters that would make what a person reads differ from what runs (invariant
/// 14): controls other than a line break or a tab, invisible format characters (bidirectional overrides and isolates,
/// zero-width spaces and joiners, soft hyphens), line and paragraph separators, and private or unassigned code points.
/// Cells, drafts and a person's own code all pass through it.
nonisolated enum CodeText {
    /// The most code a cell, a draft or one statement's Lean source may hold.
    static let maximumLength = 200_000

    /// The first character that cannot be shown as it runs, or nil.
    static func hiddenScalar(in text: String) -> Unicode.Scalar? {
        text.unicodeScalars.first { scalar in
            guard scalar != "\n", scalar != "\t" else { return false }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return true
            default: return false
            }
        }
    }

    /// A character as a refusal names it: "U+202E".
    static func name(_ scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    /// Why code cannot be kept as it is, or nil.
    static func refusal(_ text: String) -> String? {
        if text.utf8.count > maximumLength { return "The code is longer than 200 KB." }
        if let scalar = hiddenScalar(in: text) {
            return "The code holds an invisible or control character (\(name(scalar))), so what is shown would differ from what runs."
        }
        return nil
    }
}
