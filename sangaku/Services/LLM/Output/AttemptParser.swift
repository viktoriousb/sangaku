import Foundation

nonisolated struct ParsedStep: Hashable, Sendable {
    var establishes: String
    var confidence: Confidence
    var text: String
}

nonisolated struct ParsedAttempt: Hashable, Sendable {
    var overview: String
    var steps: [ParsedStep]
}

/// How an attempt's output was read. The raw output is always kept beside it, so nothing is lost either way.
nonisolated enum AttemptParse: Hashable, Sendable {
    /// The whole output, as the schema asks.
    case clean(ParsedAttempt)
    /// An attempt that ended early: the overview and the steps that were complete before it stopped.
    case partial(ParsedAttempt)
    /// Nothing could be read as steps.
    case unstructured
}

/// Reads a prover's structured attempt (`OutputFormat.attempt`). Pure; `OutputParsing` runs it off the main actor.
///
/// A step whose text holds a control character is not read. JSON turns a single backslash before some letters into
/// one: `\theta` into a tab and "heta", `\frac` into a form feed, `\beta` into a backspace, `\rho` into a carriage
/// return and `\neq` into a newline. Such output is valid JSON with silently corrupted mathematics, so it is
/// refused (invariant 16) and kept as raw text instead. The prompt asks for doubled backslashes and no line breaks
/// inside strings, so a control character never appears legitimately.
nonisolated enum AttemptParser {
    private struct StepDTO: Decodable {
        let establishes: String
        let confidence: String
        let text: String
    }

    private struct AttemptDTO: Decodable {
        let overview: String
        let steps: [StepDTO]
    }

    /// `lenient` reads what was complete in an attempt that ended early; a finished attempt is read whole or not at
    /// all.
    static func parse(_ text: String, lenient: Bool) -> AttemptParse {
        if let dto = try? JSONDecoder().decode(AttemptDTO.self, from: Data(text.utf8)),
           let overview = clean(dto.overview) {
            let steps = dto.steps.map(step)
            if !steps.contains(nil) { return .clean(ParsedAttempt(overview: overview, steps: steps.compactMap { $0 })) }
        }
        guard lenient else { return .unstructured }
        let scanned = scan(text)
        guard !scanned.steps.isEmpty || !scanned.overview.isEmpty else { return .unstructured }
        return .partial(scanned)
    }

    /// The steps complete so far in output that is still arriving, for an attempt card while it streams.
    static func progress(_ text: String) -> [ParsedStep] {
        scan(text).steps
    }

    private static func step(_ dto: StepDTO) -> ParsedStep? {
        guard let confidence = Confidence(rawValue: dto.confidence),
              let establishes = clean(dto.establishes), let text = clean(dto.text) else { return nil }
        return ParsedStep(establishes: establishes, confidence: confidence, text: text)
    }

    /// Trimmed, or nil when the string holds a control character (see the type's note).
    static func clean(_ string: String) -> String? {
        guard !string.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        return string.trimmingCharacters(in: .whitespaces)
    }

    /// The overview and the step objects that are complete in JSON text that may be cut off. Steps are read in
    /// order and the scan stops at the first one that cannot be read, so the result is always a prefix.
    private static func scan(_ text: String) -> ParsedAttempt {
        var result = ParsedAttempt(overview: "", steps: [])
        var scanner = JSONScanner(text)
        guard scanner.consume(UInt8(ascii: "{")) else { return result }
        while true {
            scanner.skipWhitespace()
            guard let key = scanner.string() else { return result }
            scanner.skipWhitespace()
            guard scanner.consume(UInt8(ascii: ":")) else { return result }
            scanner.skipWhitespace()
            if key == "steps" {
                guard scanner.consume(UInt8(ascii: "[")) else { return result }
                while true {
                    scanner.skipWhitespace()
                    if scanner.consume(UInt8(ascii: "]")) { break }
                    if scanner.consume(UInt8(ascii: ",")) { continue }
                    guard let raw = scanner.value(),
                          let dto = try? JSONDecoder().decode(StepDTO.self, from: Data(raw.utf8)),
                          let parsed = step(dto) else { return result }
                    result.steps.append(parsed)
                }
            } else {
                guard let raw = scanner.value() else { return result }
                if key == "overview", let value = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)),
                   let overview = clean(value) {
                    result.overview = overview
                }
            }
            scanner.skipWhitespace()
            guard scanner.consume(UInt8(ascii: ",")) else { return result }
        }
    }
}

/// Walks JSON text that may be cut off. Every read returns nil, and consumes nothing, when the text ends before
/// the value does.
nonisolated struct JSONScanner {
    private let bytes: [UInt8]
    private var position = 0

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    mutating func skipWhitespace() {
        while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        skipWhitespace()
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }

    /// A complete string, decoded.
    mutating func string() -> String? {
        guard position < bytes.count, bytes[position] == UInt8(ascii: "\""), let raw = value() else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
    }

    /// The raw text of the complete JSON value that starts here.
    mutating func value() -> String? {
        guard let end = Self.valueEnd(bytes, from: position) else { return nil }
        let raw = String(decoding: bytes[position..<end], as: UTF8.self)
        position = end
        return raw
    }

    private static func valueEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            var index = start + 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"): index += 2
                case UInt8(ascii: "\""): return index + 1
                default: index += 1
                }
            }
            return nil
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var inString = false
            var index = start
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if byte == UInt8(ascii: "\\") { index += 1 } else if byte == UInt8(ascii: "\"") { inString = false }
                } else {
                    switch byte {
                    case UInt8(ascii: "\""): inString = true
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { return index + 1 }
                    default: break
                    }
                }
                index += 1
            }
            return nil
        default:
            // A number or a literal: complete only once something follows it.
            var index = start
            while index < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D]
                .contains(bytes[index]) {
                index += 1
            }
            return index < bytes.count ? index : nil
        }
    }
}
