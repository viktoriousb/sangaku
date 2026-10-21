import Foundation
import SwiftData

extension SangakuSchemaV1 {
    /// A formalizer's Lean code for a statement, as it arrived on its message. Written once by `ThreadManager` and
    /// never edited: a person who changes it checks their own text, which `LeanResult` then records as theirs.
    @Model final class LeanDraft {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var statementID: UUID?
        /// Definitions the statement needs, then `theorem main …` up to its type (`LeanSource`).
        @Attribute(.externalStorage) var statementPart: String = ""
        /// The proof, beginning with `:=`. The formalizer's note is its message's text.
        @Attribute(.externalStorage) var proofPart: String = ""
        var message: Message?

        init(statementID: UUID? = nil, statementPart: String = "", proofPart: String = "") {
            self.statementID = statementID
            self.statementPart = statementPart
            self.proofPart = proofPart
        }
    }

    /// A self-contained computation (GAP, Sage or Python), attached to the message that carries it: a scout's, or a
    /// person's. Its code never changes; an edit is a new cell. It runs only when a person clicks Run on the code
    /// shown (invariant 14), and each run is recorded as `Evidence`.
    @Model final class ComputeCell {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var toolRaw: String = EvidenceTool.fallback.rawValue
        @Attribute(.externalStorage) var code: String = ""
        /// Exactly what the computation covers ("every group of order p²q ≤ 100").
        var scope: String = ""
        /// The claim it tests, in the words of whoever wrote it. A scout's note is its message's text.
        var claim: String = ""
        /// The statement a run's evidence is attached to.
        var statementID: UUID?
        /// The cell this one was edited from.
        var basedOnCellID: UUID?
        var message: Message?
        @Relationship(deleteRule: .nullify, inverse: \Evidence.cell)
        var runs: [Evidence]? = []

        init(tool: EvidenceTool = .python, code: String = "", scope: String = "", claim: String = "",
             statementID: UUID? = nil) {
            self.toolRaw = tool.rawValue
            self.code = code
            self.scope = scope
            self.claim = claim
            self.statementID = statementID
        }

        var tool: EvidenceTool {
            get { EvidenceTool(stored: toolRaw) }
            set { toolRaw = newValue.rawValue }
        }
    }
}
