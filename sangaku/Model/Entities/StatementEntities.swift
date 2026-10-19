import Foundation
import SwiftData

extension SangakuSchemaV1 {
    /// A theorem, lemma, claim or conjecture. Its status is derived (`StatusRules`), never stored.
    @Model final class Statement {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var kindRaw: String = StatementKind.fallback.rawValue
        var label: String = ""
        var statementLaTeX: String = ""
        var authorKindRaw: String?
        var authorID: UUID?
        var problem: Problem?

        @Relationship(deleteRule: .nullify, inverse: \Step.statements)
        var sourceSteps: [Step]? = []
        /// What this statement uses. Acyclic; enforced in code.
        @Relationship(deleteRule: .nullify, inverse: \Statement.usedBy)
        var uses: [Statement]? = []
        var usedBy: [Statement]? = []

        @Relationship(deleteRule: .cascade, inverse: \LeanResult.statement)
        var leanResult: LeanResult?
        @Relationship(deleteRule: .cascade, inverse: \FidelityReview.statement)
        var fidelityReviews: [FidelityReview]? = []
        @Relationship(deleteRule: .cascade, inverse: \Evidence.statement)
        var evidence: [Evidence]? = []

        /// A proposed refutation (counterexample evidence or a confirmed ✗). Only a person accepts it.
        var refutationEvidenceID: UUID?
        var refutationNote: String?
        var refutationAcceptedByID: UUID?
        var refutationAcceptedAt: Date?

        init(kind: StatementKind = .claim, label: String = "", statementLaTeX: String = "", author: Author? = nil) {
            self.kindRaw = kind.rawValue
            self.label = label
            self.statementLaTeX = statementLaTeX
            self.author = author
        }

        var kind: StatementKind {
            get { StatementKind(stored: kindRaw) }
            set { kindRaw = newValue.rawValue }
        }

        var author: Author? {
            get { Author(kind: authorKindRaw, id: authorID) }
            set { authorKindRaw = newValue?.stored.kind; authorID = newValue?.stored.id }
        }
    }

    /// A person's judgment that a Lean statement does (or does not) say what the informal statement says,
    /// given for one exact `leanStatementSource` (invariant 12).
    @Model final class FidelityReview {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var reviewerID: UUID?
        var leanStatementSource: String = ""
        var verdictRaw: String = FidelityVerdict.fallback.rawValue
        var comment: String?
        var statement: Statement?

        init(reviewer: PersonID? = nil, leanStatementSource: String = "", verdict: FidelityVerdict = .differs) {
            self.reviewerID = reviewer?.rawValue
            self.leanStatementSource = leanStatementSource
            self.verdictRaw = verdict.rawValue
        }

        var verdict: FidelityVerdict {
            get { FidelityVerdict(stored: verdictRaw) }
            set { verdictRaw = newValue.rawValue }
        }
    }

    /// Output of a computation attached to a statement. `scope` says exactly what was tested.
    @Model final class Evidence {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var toolRaw: String = EvidenceTool.fallback.rawValue
        @Attribute(.externalStorage) var code: String = ""
        @Attribute(.externalStorage) var output: String = ""
        var passed: Bool = false
        var scope: String = ""
        var toolVersion: String = ""
        var statement: Statement?

        init(tool: EvidenceTool = .python, code: String = "", output: String = "", passed: Bool = false, scope: String = "") {
            self.toolRaw = tool.rawValue
            self.code = code
            self.output = output
            self.passed = passed
            self.scope = scope
        }

        var tool: EvidenceTool {
            get { EvidenceTool(stored: toolRaw) }
            set { toolRaw = newValue.rawValue }
        }
    }

    /// The result of checking a statement's Lean formalization.
    @Model final class LeanResult {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        @Attribute(.externalStorage) var source: String = ""
        var leanStatementSource: String = ""
        var sorryCount: Int = 0
        var messagesJSON: Data?
        /// Output of `#print axioms` for the checked declaration.
        var axioms: [String] = []
        var checkedAt: Date?
        var statement: Statement?

        init(source: String = "", leanStatementSource: String = "", sorryCount: Int = 0, axioms: [String] = []) {
            self.source = source
            self.leanStatementSource = leanStatementSource
            self.sorryCount = sorryCount
            self.axioms = axioms
        }

        var messages: [LeanMessage] {
            get { JSONColumn.decode([LeanMessage].self, from: messagesJSON) ?? [] }
            set { messagesJSON = JSONColumn.encode(newValue) }
        }

        var errors: [LeanMessage] { messages.filter { $0.severity == "error" } }

        /// False when stored messages exist but cannot be decoded: then "no errors" would be a guess.
        var messagesAreReadable: Bool {
            messagesJSON == nil || JSONColumn.decode([LeanMessage].self, from: messagesJSON) != nil
        }
    }
}
