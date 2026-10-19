import Foundation

nonisolated enum ProseSegment: Hashable, Sendable {
    case text(String)
    case math(String, MathStyle)
    /// An opening delimiter with no closing one: shown as a source chip, never silently as prose.
    case unterminated(String)
}

/// Splits prose into text and math. Delimiters: `$…$` and `\(…\)` inline, `$$…$$` and `\[…\]` display;
/// `\$` is a literal dollar sign in text.
nonisolated enum ProseSegmenter {
    static func segments(_ source: String) -> [ProseSegment] {
        var out: [ProseSegment] = []
        var text = ""
        var rest = source[...]
        func flushText() {
            if !text.isEmpty { out.append(.text(text)); text = "" }
        }
        while let c = rest.first {
            if rest.hasPrefix("\\$") {
                text.append("$")
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("$$") || rest.hasPrefix("\\[") || c == "$" || rest.hasPrefix("\\(") {
                let (open, close, style): (String, String, MathStyle) =
                    rest.hasPrefix("$$") ? ("$$", "$$", .display)
                    : rest.hasPrefix("\\[") ? ("\\[", "\\]", .display)
                    : rest.hasPrefix("\\(") ? ("\\(", "\\)", .inline)
                    : ("$", "$", .inline)
                let body = rest.dropFirst(open.count)
                if let end = closingRange(of: close, in: body) {
                    flushText()
                    out.append(.math(String(body[..<end.lowerBound]), style))
                    rest = body[end.upperBound...]
                } else {
                    flushText()
                    out.append(.unterminated(String(rest)))
                    rest = rest[rest.endIndex...]
                }
            } else {
                text.append(c)
                rest = rest.dropFirst()
            }
        }
        flushText()
        return out
    }

    /// The first `close` not escaped by a backslash.
    private static func closingRange(of close: String, in body: Substring) -> Range<Substring.Index>? {
        var search = body[...]
        while let range = search.range(of: close) {
            let before = body[..<range.lowerBound]
            if close == "$" || close == "$$", before.last == "\\" {
                search = body[range.upperBound...]
                continue
            }
            return range
        }
        return nil
    }
}
