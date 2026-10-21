import Foundation

/// A structured output a request asks for, through the provider's JSON-schema output. A prose request has none.
nonisolated enum OutputFormat: Hashable, Sendable {
    /// A prover's attempt: an overview and numbered steps, each with what it establishes, a confidence label and the
    /// outside results it cites.
    case attempt
    /// A referee's verdict on each attempt, identified by the letter of the slot that wrote it, and a summary.
    case refereeVerdicts(letters: [String])
    /// Two attempts' steps paired by what they establish, each pair judged, and a summary. The attempts are named
    /// "Attempt 1" and "Attempt 2" only; a step number of 0 means none, an empty phrase means none.
    case alignment
    /// A formalizer's Lean code for one statement: a note to the people reading it, the statement part (definitions,
    /// then `theorem main` and its type) and the proof part (from `:=`).
    case leanDraft
    /// A scout's computation: a note, the tool (one of those that can run), the claim, its exact scope, the code.
    case computeCell(tools: [String])

    /// Recorded with the request's parameters.
    var tag: String {
        switch self {
        case .attempt: "proof-attempt@2"
        case .refereeVerdicts: "referee-verdicts@1"
        case .alignment: "alignment@1"
        case .leanDraft: "lean-draft@1"
        case .computeCell: "compute-cell@1"
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
            "required":["text","establishes","confidence","citations"],"properties":{\#
            "text":{"type":"string"},\#
            "establishes":{"type":"string"},\#
            "confidence":{"type":"string","enum":["standard","routine","delicate","guess"]},\#
            "citations":{"type":"array","items":{"type":"string"}}}}}}}
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
        case .leanDraft:
            #"""
            {"type":"object","additionalProperties":false,"required":["note","statement_part","proof_part"],"properties":{\#
            "note":{"type":"string"},\#
            "statement_part":{"type":"string"},\#
            "proof_part":{"type":"string"}}}
            """#
        case .computeCell(let tools):
            #"""
            {"type":"object","additionalProperties":false,"required":["note","tool","claim","scope","code"],"properties":{\#
            "note":{"type":"string"},\#
            "tool":{"type":"string","enum":\#(Self.jsonArray(tools))},\#
            "claim":{"type":"string"},\#
            "scope":{"type":"string"},\#
            "code":{"type":"string"}}}
            """#
        }
    }

    private static func jsonArray(_ strings: [String]) -> String {
        (try? JSONEncoder().encode(strings)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
