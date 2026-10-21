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
        /// The informal statement as the person read it: a review given on other wording does not count.
        var informalWording: String = ""
        /// When the reviewer took it back; it stays in the history and counts for nothing.
        var withdrawnAt: Date?
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

    /// One run of a computation attached to a statement: the exact code a person ran, what it printed and how it
    /// ended. `scope` says exactly what was tested. Every run that started is recorded, failures included.
    @Model final class Evidence {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var toolRaw: String = EvidenceTool.fallback.rawValue
        @Attribute(.externalStorage) var code: String = ""
        @Attribute(.externalStorage) var output: String = ""
        /// The run completed and its code reported that the claim held over the scope.
        var passed: Bool = false
        var scope: String = ""
        var toolVersion: String = ""
        var statement: Statement?
        /// The cell that was run, and the person who clicked Run.
        var cell: ComputeCell?
        var runByID: UUID?
        var startedAt: Date?
        var outcomeRaw: String = RunOutcome.fallback.rawValue
        var verdictRaw: String = CellVerdict.fallback.rawValue
        var exitCode: Int?
        var durationSeconds: Double = 0
        /// Output was cut to fit; what was kept is the start and the end.
        var truncated: Bool = false
        @Attribute(.externalStorage) var errorText: String = ""

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

        var outcome: RunOutcome {
            get { RunOutcome(stored: outcomeRaw) }
            set { outcomeRaw = newValue.rawValue }
        }

        var verdict: CellVerdict {
            get { CellVerdict(stored: verdictRaw) }
            set { verdictRaw = newValue.rawValue }
        }
    }

    /// The result of checking a statement's Lean formalization. Only `LeanResult.record` writes the axiom fields, from
    /// the service's own reading of the check (`LeanOutputReader`).
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
        /// The declaration whose service-appended `#print axioms` line was read. Empty when that line did not report:
        /// then `axioms` means nothing, and rule 2 fails closed.
        var axiomCheckedDeclaration: String = ""
        /// SHA-256 of `source` as checked: a later change to the text disqualifies the result.
        var checkedDigest: String = ""
        /// SHA-256 of the whole module the check ran (one per problem).
        var moduleDigest: String = ""
        var sorryLocationsJSON: Data?
        var toolchain: String = ""
        var leanVersion: String = ""
        var mathlibRev: String = ""
        var durationSeconds: Double = 0
        /// The person who clicked Check, and who wrote the source: the formalizer whose draft it is, unchanged, or the
        /// person.
        var checkedByID: UUID?
        var sourceAuthorKindRaw: String?
        var sourceAuthorID: UUID?
        var draftMessageID: UUID?

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

        var sorryLocations: [LeanLocation] {
            get { JSONColumn.decode([LeanLocation].self, from: sorryLocationsJSON) ?? [] }
            set { sorryLocationsJSON = JSONColumn.encode(newValue) }
        }

        var sourceAuthor: Author? {
            get { Author(kind: sourceAuthorKindRaw, id: sourceAuthorID) }
            set { sourceAuthorKindRaw = newValue?.stored.kind; sourceAuthorID = newValue?.stored.id }
        }

        /// What the stored fields say about the axiom check.
        var axiomCheck: AxiomCheck {
            axiomCheckedDeclaration.isEmpty ? .notRun : .ran(declaration: axiomCheckedDeclaration, axioms: axioms)
        }

        /// False when stored messages exist but cannot be decoded: then "no errors" would be a guess.
        var messagesAreReadable: Bool {
            messagesJSON == nil || JSONColumn.decode([LeanMessage].self, from: messagesJSON) != nil
        }
    }
}
