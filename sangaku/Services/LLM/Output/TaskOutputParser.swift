import Foundation

/// A formalizer's answer, as read.
nonisolated struct LeanDraftReport: Hashable, Sendable {
    var note: String
    var source: LeanSource
}

/// A scout's answer, as read.
nonisolated struct ComputeCellReport: Hashable, Sendable {
    var note: String
    var tool: EvidenceTool
    var claim: String
    var scope: String
    var code: String
}

/// Reads formalizer and scout answers whole or not at all; anything unreadable is kept as the raw text by the caller.
/// Prose fields refuse control characters as attempts do (`AttemptParser.clean`: a lost backslash corrupts LaTeX);
/// code fields must pass `CodeText`, so nothing in them is hidden from the person who runs them. Nothing here runs or
/// checks the code.
nonisolated enum TaskOutputParser {
    private struct DraftDTO: Decodable {
        let note: String
        let statementPart: String
        let proofPart: String

        enum CodingKeys: String, CodingKey {
            case note
            case statementPart = "statement_part"
            case proofPart = "proof_part"
        }
    }

    private struct CellDTO: Decodable {
        let note: String
        let tool: String
        let claim: String
        let scope: String
        let code: String
    }

    static func leanDraft(_ text: String) -> LeanDraftReport? {
        guard let dto = try? JSONDecoder().decode(DraftDTO.self, from: Data(text.utf8)),
              let note = AttemptParser.clean(dto.note), let statement = code(dto.statementPart),
              let proof = code(dto.proofPart) else { return nil }
        let source = LeanSource(statementPart: statement, proofPart: proof)
        guard !source.statementPart.isEmpty, !source.proofPart.isEmpty else { return nil }
        return LeanDraftReport(note: note, source: source)
    }

    /// `tools` are those the scout was told can run; any other tool makes the answer unreadable.
    static func computeCell(_ text: String, tools: [EvidenceTool]) -> ComputeCellReport? {
        guard let dto = try? JSONDecoder().decode(CellDTO.self, from: Data(text.utf8)),
              let tool = EvidenceTool(rawValue: dto.tool), tools.contains(tool),
              let note = AttemptParser.clean(dto.note), let claim = AttemptParser.clean(dto.claim),
              let scope = AttemptParser.clean(dto.scope), !scope.isEmpty,
              let source = code(dto.code), !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ComputeCellReport(note: note, tool: tool, claim: claim, scope: scope, code: source)
    }

    /// Code as written, or nil when `CodeText` refuses it.
    static func code(_ string: String) -> String? {
        CodeText.refusal(string) == nil ? string : nil
    }
}
