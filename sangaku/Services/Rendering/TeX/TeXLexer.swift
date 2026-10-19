import Foundation

/// One TeX token. Every TeX consumer in the app (macro parsing and expansion, the typographic tier, the
/// MicroTeX rewrites) shares this tokenizer instead of scanning characters on its own.
nonisolated enum TeXToken: Hashable, Sendable {
    /// A control word such as `\frac` (name without the backslash).
    case command(String)
    /// A control symbol such as `\,` or `\{`.
    case symbol(Character)
    case open
    case close
    /// A run of whitespace, kept so the source can be rebuilt faithfully.
    case space(String)
    case char(Character)
}

nonisolated enum TeXLexer {
    /// Tokenizes `source`. With `stripComments`, an unescaped `%` starts a comment that runs to the end of
    /// the line (preambles); in formulas it is kept as a character.
    static func tokens(_ source: String, stripComments: Bool = false) -> [TeXToken] {
        tokensWithLines(source, stripComments: stripComments).map(\.token)
    }

    /// Tokens with the 1-based line each starts on.
    static func tokensWithLines(_ source: String, stripComments: Bool = false) -> [(token: TeXToken, line: Int)] {
        var out: [(TeXToken, Int)] = []
        var chars = normalizingNewlines(source)[...]
        var line = 1
        while let c = chars.first {
            let startLine = line
            if c == "\\" {
                chars.removeFirst()
                guard let next = chars.first else { out.append((.symbol("\\"), startLine)); break }
                if next.isASCII && next.isLetter {
                    var name = ""
                    while let l = chars.first, l.isASCII && l.isLetter { name.append(l); chars.removeFirst() }
                    out.append((.command(name), startLine))
                } else {
                    chars.removeFirst()
                    if next == "\n" { line += 1 }
                    out.append((.symbol(next), startLine))
                }
            } else if c == "%" && stripComments {
                while let l = chars.first, l != "\n" { chars.removeFirst() }
            } else if c.isWhitespace {
                var run = ""
                while let w = chars.first, w.isWhitespace {
                    if w == "\n" { line += 1 }
                    run.append(w)
                    chars.removeFirst()
                }
                out.append((.space(run), startLine))
            } else {
                chars.removeFirst()
                switch c {
                case "{": out.append((.open, startLine))
                case "}": out.append((.close, startLine))
                default: out.append((.char(c), startLine))
                }
            }
        }
        return out
    }

    /// Windows (`\r\n`) and old Mac (`\r`) line ends as `\n`. In Swift `"\r\n"` is one `Character`, so without this
    /// a `%` comment would run to the end of the file and every token would be on line 1.
    static func normalizingNewlines(_ source: String) -> String {
        source.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
    }

    /// Rebuilds source from tokens. A control word directly followed by a letter gets a separating space,
    /// so splicing never fuses `\alpha` and `x` into `\alphax`.
    static func string(_ tokens: some Collection<TeXToken>) -> String {
        var out = ""
        var previousWasWord = false
        for token in tokens {
            switch token {
            case .command(let name):
                out += "\\" + name
                previousWasWord = true
                continue
            case .symbol(let c):
                out += "\\" + String(c)
            case .open:
                out += "{"
            case .close:
                out += "}"
            case .space(let s):
                out += s
            case .char(let c):
                if previousWasWord && c.isLetter { out += " " }
                out.append(c)
            }
            previousWasWord = false
        }
        return out
    }
}

/// Reading arguments from a token array.
nonisolated extension Array where Element == TeXToken {
    /// Index of the first non-space token at or after `index`.
    func skippingSpaces(from index: Int) -> Int {
        var i = index
        while i < count, case .space = self[i] { i += 1 }
        return i
    }

    /// A balanced `{…}` group starting at `index` (which must be `.open`): its contents and the index after it.
    func group(at index: Int) -> (contents: [TeXToken], end: Int)? {
        guard index < count, self[index] == .open else { return nil }
        var depth = 0
        var i = index
        while i < count {
            switch self[i] {
            case .open: depth += 1
            case .close:
                depth -= 1
                if depth == 0 { return (Array(self[(index + 1)..<i]), i + 1) }
            default: break
            }
            i += 1
        }
        return nil
    }

    /// One macro argument after optional spaces: a group's contents, or a single token.
    func argument(at index: Int) -> (contents: [TeXToken], end: Int)? {
        let i = skippingSpaces(from: index)
        guard i < count else { return nil }
        if self[i] == .open { return group(at: i) }
        if self[i] == .close { return nil }
        return ([self[i]], i + 1)
    }
}
