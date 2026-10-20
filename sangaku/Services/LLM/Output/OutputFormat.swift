import Foundation

/// A structured output a request asks for, through the provider's JSON-schema output. A prose request has none.
nonisolated enum OutputFormat: Hashable, Sendable {
    /// A prover's attempt: an overview and numbered steps, each with what it establishes and a confidence label.
    case attempt
    /// A referee's verdict on each attempt, identified by the letter of the slot that wrote it, and a summary.
    case refereeVerdicts(letters: [String])
    /// Two attempts' steps paired by what they establish, each pair judged, and a summary. The attempts are named
    /// "Attempt 1" and "Attempt 2" only; a step number of 0 means none, an empty phrase means none.
    case alignment

    /// Recorded with the request's parameters.
    var tag: String {
        switch self {
        case .attempt: "proof-attempt@1"
        case .refereeVerdicts: "referee-verdicts@1"
        case .alignment: "alignment@1"
        }
    }

    /// The JSON schema as JSON text, sent exactly as written. Every object is closed and lists all its properties as
    /// required, as the provider's structured output requires; nothing is recursive and nothing has a length or
    /// number bound. Properties come in the order the model should write them: a step's text before what it
    /// establishes and how confident it is; a verdict's reasons before its outcome; the verdicts before the summary.
    var schemaJSON: String {
        switch self {
        case .attempt:
            #"""
            {"type":"object","additionalProperties":false,"required":["overview","steps"],"properties":{\#
            "overview":{"type":"string"},\#
            "steps":{"type":"array","items":{"type":"object","additionalProperties":false,\#
            "required":["text","establishes","confidence"],"properties":{\#
            "text":{"type":"string"},\#
            "establishes":{"type":"string"},\#
            "confidence":{"type":"string","enum":["standard","routine","delicate","guess"]}}}}}}
            """#
        case .refereeVerdicts(let letters):
            #"""
            {"type":"object","additionalProperties":false,"required":["verdicts","summary"],"properties":{\#
            "verdicts":{"type":"array","items":{"type":"object","additionalProperties":false,\#
            "required":["attempt","rationale","gap_steps","outcome"],"properties":{\#
            "attempt":{"type":"string","enum":\#(Self.jsonArray(letters))},\#
            "rationale":{"type":"string"},\#
            "gap_steps":{"type":"array","items":{"type":"integer"}},\#
            "outcome":{"type":"string","enum":["complete","gap"]}}}},\#
            "summary":{"type":"string"}}}
            """#
        case .alignment:
            #"""
            {"type":"object","additionalProperties":false,"required":["rows","summary"],"properties":{\#
            "rows":{"type":"array","items":{"type":"object","additionalProperties":false,\#
            "required":["label","step_1","step_2","note","phrase_1","phrase_2","verdict"],"properties":{\#
            "label":{"type":"string"},\#
            "step_1":{"type":"integer"},\#
            "step_2":{"type":"integer"},\#
            "note":{"type":"string"},\#
            "phrase_1":{"type":"string"},\#
            "phrase_2":{"type":"string"},\#
            "verdict":{"type":"string","enum":["equivalent","diverge","only_1","only_2"]}}}},\#
            "summary":{"type":"string"}}}
            """#
        }
    }

    private static func jsonArray(_ strings: [String]) -> String {
        (try? JSONEncoder().encode(strings)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
