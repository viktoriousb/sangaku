import Foundation

/// Reads model output off the main actor. The parsers themselves are pure and synchronous; quitting uses them
/// directly, since the final save follows at once.
nonisolated enum OutputParsing {
    @concurrent static func attempt(_ text: String, lenient: Bool) async -> AttemptParse {
        AttemptParser.parse(text, lenient: lenient)
    }

    @concurrent static func referee(_ text: String) async -> RefereeReport? {
        RefereeParser.parse(text)
    }

    @concurrent static func alignment(_ text: String) async -> AlignmentReport? {
        AlignmentParser.parse(text)
    }

    @concurrent static func leanDraft(_ text: String) async -> LeanDraftReport? {
        TaskOutputParser.leanDraft(text)
    }

    @concurrent static func computeCell(_ text: String, tools: [EvidenceTool]) async -> ComputeCellReport? {
        TaskOutputParser.computeCell(text, tools: tools)
    }

    @concurrent static func progress(_ text: String) async -> [ParsedStep] {
        AttemptParser.progress(text)
    }
}
