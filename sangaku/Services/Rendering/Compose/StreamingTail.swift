import Foundation

/// Splits a reply that is still streaming into the part whose math is closed and a pending tail that opens
/// math the stream has not closed yet. The tail is shown as plain pending text until its closing delimiter
/// arrives, instead of flashing a "never closed" warning. A finished reply is rendered whole, so a delimiter that
/// is really missing still shows as a source chip (invariant 16).
nonisolated enum StreamingTail {
    static func split(_ text: String) -> (closed: String, pending: String) {
        guard case .unterminated(let rest)? = ProseSegmenter.segments(text).last,
              let range = text.range(of: rest, options: [.backwards, .anchored]) else { return (text, "") }
        return (String(text[..<range.lowerBound]), rest)
    }
}
