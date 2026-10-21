import Foundation

/// A document an index returned for a citation.
nonisolated struct CitationCandidate: Hashable, Sendable {
    var index: String
    var title: String
    /// Surnames, as the index gives authors ("Dummit, David S." gives "Dummit").
    var surnames: [String]
    var year: Int?
    var url: String?
}

/// What one index said: the documents it returned, or why it could not answer.
nonisolated enum IndexAnswer: Hashable, Sendable {
    case candidates([CitationCandidate])
    case failed(String)
}

/// The outcome of looking a citation up, as it is recorded.
nonisolated enum CitationVerdict: Hashable, Sendable {
    /// A document matching the citation exists; that is all it says.
    case found(CitationCandidate)
    /// Every index answered and none had a matching document.
    case notFound
    /// The lookup could not decide: an index failed, or the citation says too little to look up.
    case unverified(String)
}

/// The rules of citation lookups (invariant 6), pure so they are tested without the network: what is sent, when a
/// returned document matches, what an outcome is recorded as, and when a citation may be shown as a link.
nonisolated enum CitationRules {
    static let indexes = ["arXiv", "zbMATH Open"]
    /// The hosts a resolved link may point to.
    static let linkHosts = ["arxiv.org", "zbmath.org"]

    private static let stopWords: Set<String> = [
        "the", "and", "of", "in", "on", "for", "a", "an", "to", "with", "by", "from", "at", "de", "der", "und", "la",
        "lemma", "theorem", "thm", "proposition", "prop", "corollary", "cor", "section", "sec", "chapter", "ch",
        "definition", "remark", "example", "exercise", "ed", "edition", "vol", "volume", "pp", "page", "pages", "p",
        "no", "journal", "j", "math", "proc", "trans", "ann", "et", "al",
    ]

    /// The words of a citation worth searching for: LaTeX commands and mathematics left out, lower case, at least three
    /// letters, no stop words, each once, at most eight.
    static func terms(_ raw: String) -> [String] {
        var words: [String] = []
        for word in plain(raw).lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        where word.count >= 3 && !stopWords.contains(word) && !words.contains(word) {
            words.append(word)
            if words.count == 8 { break }
        }
        return words
    }

    /// The first three search terms: in most citations the author and the start of the title. A second, wider arXiv
    /// query when every term together finds nothing; still only words of the query shown.
    static func narrowTerms(_ raw: String) -> [String] {
        Array(terms(raw).prefix(3))
    }

    /// The years a citation names.
    static func years(_ raw: String) -> [Int] {
        plain(raw).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1800...2100).contains($0) }
    }

    /// The citation without LaTeX commands, math delimiters or braces.
    static func plain(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"\\[A-Za-z]+"#, with: " ", options: .regularExpression)
        for mark in ["$", "{", "}", "\\", "~"] { text = text.replacingOccurrences(of: mark, with: " ") }
        return text
    }

    /// Exactly the text sent for a citation: its search terms, and its year for the index that searches years. Nothing
    /// else of the problem leaves the Mac.
    static func query(_ raw: String) -> String {
        (terms(raw) + years(raw).prefix(1).map(String.init)).joined(separator: " ")
    }

    /// Enough to look up: two search terms at least.
    static func canLookUp(_ raw: String) -> Bool { terms(raw).count >= 2 }

    /// A returned document matches when one of its authors is named in the citation, at least half of its title's
    /// words are, and the years agree (within one, for a preprint and its publication) when both have one.
    static func matches(_ raw: String, _ candidate: CitationCandidate) -> Bool {
        let words = Set(plain(raw).lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let author = candidate.surnames.contains { surname in
            surname.lowercased().split(whereSeparator: { !$0.isLetter }).contains { words.contains(String($0)) }
        }
        let title = candidate.title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        guard author, !title.isEmpty else { return false }
        let shared = title.filter(words.contains).count
        guard Double(shared) / Double(title.count) >= 0.5 else { return false }
        if let year = candidate.year, let cited = years(raw).first { return abs(year - cited) <= 1 }
        return true
    }

    /// The outcome from every index's answer. A failed lookup is never "not found".
    static func verdict(_ raw: String, answers: [(index: String, answer: IndexAnswer)]) -> CitationVerdict {
        for (_, answer) in answers {
            if case .candidates(let candidates) = answer, let match = candidates.first(where: { matches(raw, $0) }) {
                return .found(match)
            }
        }
        let failures = answers.compactMap { index, answer -> String? in
            if case .failed(let reason) = answer { "\(index): \(reason)" } else { nil }
        }
        return failures.isEmpty && !answers.isEmpty ? .notFound : .unverified(failures.joined(separator: "; "))
    }

    /// A link to show for a citation: only a found one, only over https, only to an index's own site (invariant 6).
    static func link(status: CitationStatus, url: String?) -> URL? {
        guard status == .found, let url, let components = URLComponents(string: url), components.scheme == "https",
              let host = components.host?.lowercased(),
              linkHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return components.url
    }
}
