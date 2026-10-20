import Foundation

/// Wording shared by the views and by what models are told.
nonisolated enum Prose {
    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }

    /// "1 step", "2 steps". For nouns that take an s.
    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// The same for a noun whose plural is not a plain "s": "4 entries".
    static func count(_ number: Int, _ noun: String, plural: String) -> String {
        "\(number) \(number == 1 ? noun : plural)"
    }
}
