import Foundation

/// What an export writes, in no file format yet. Every text in it is a `TeXFragment`, so it exists only when every
/// text passed the gate; `ExportComposer` is its one maker.
nonisolated struct ExportDocument: Hashable, Sendable {
    nonisolated enum Environment: String, Hashable, Sendable {
        case theorem, lemma, claim, conjecture

        init(_ kind: StatementKind) {
            self = switch kind {
            case .theorem: .theorem
            case .lemma: .lemma
            case .claim: .claim
            case .conjecture: .conjecture
            }
        }

        /// The environment's name, which is also the word a reference to it uses ("Lemma~\ref{…}").
        var name: TeXFragment {
            switch self {
            case .theorem: "theorem"
            case .lemma: "lemma"
            case .claim: "claim"
            case .conjecture: "conjecture"
            }
        }

        var word: TeXFragment {
            switch self {
            case .theorem: "Theorem"
            case .lemma: "Lemma"
            case .claim: "Claim"
            case .conjecture: "Conjecture"
            }
        }
    }

    /// Where an item goes in the manuscript.
    nonisolated enum Group: Int, Hashable, Sendable, CaseIterable, Comparable {
        case imported, lemmas, main, open, refuted

        static func < (lhs: Group, rhs: Group) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Where a statement goes and how it is written: refuted and imported ones by their kind and with no proof, one with
    /// steps by its kind with its proof, and one without steps as a conjecture.
    static func placement(of statement: ExportStatement) -> (group: Group, environment: Environment) {
        if statement.derived.own == .refuted { return (.refuted, Environment(statement.kind)) }
        if statement.importedSource != nil { return (.imported, Environment(statement.kind)) }
        if statement.sources.isEmpty { return (.open, .conjecture) }
        return (statement.isPinned ? .main : .lemmas, Environment(statement.kind))
    }

    nonisolated struct Step: Hashable, Sendable {
        var number: Int
        var establishes: TeXFragment
        var text: TeXFragment
        var provenance: TeXFragment
        var citations: [TeXFragment]
    }

    /// The steps of a proof that come from one attempt.
    nonisolated struct ProofPart: Hashable, Sendable {
        var source: TeXFragment
        var steps: [Step]
    }

    nonisolated struct Item: Hashable, Sendable, Identifiable {
        var id: UUID
        var group: Group
        var environment: Environment
        var label: TeXFragment
        /// The statement's label in the app, "Lem 1".
        var name: TeXFragment
        /// The optional argument, braced: the name, and `\imported{…}` for a result from the literature.
        var title: TeXFragment
        var statement: TeXFragment
        var status: [TeXFragment]
        /// "Uses Lemma~\ref{…}." when it uses other exported statements.
        var uses: TeXFragment?
        /// Empty: no proof is written (imported, refuted, or no steps).
        var proof: [ProofPart]
        /// A refuted statement: the refutation a person accepted.
        var refutation: TeXFragment?
        /// The status table's short form.
        var statusWords: TeXFragment
        /// A result from the literature: where it is from.
        var importedSource: TeXFragment?
    }

    /// A found citation, from what the index returned only.
    nonisolated struct Reference: Hashable, Sendable {
        var key: TeXFragment
        var authors: [TeXFragment]
        var title: TeXFragment
        var year: Int?
        var link: TeXFragment?
        var index: TeXFragment
    }

    nonisolated struct NotationLine: Hashable, Sendable {
        var symbol: TeXFragment
        var meaning: TeXFragment
    }

    var scope: ExportScope
    /// The problem's title, for `\title{…}`: one line, not braced.
    var title: TeXFragment
    /// Dependencies before what uses them; the theorem after everything it uses.
    var items: [Item]
    var aiUse: [TeXFragment]
    var references: [Reference]
    var notation: [NotationLine]
    var macros: [TeXFragment]
    /// What the theorem's steps establish, in order: the argument in a few steps.
    var argument: [TeXFragment]
    var theorem: Item? { items.first { $0.group == .main } }
}

/// Why an export did not happen. Nothing is written to the folder in any of these cases.
nonisolated enum ExportError: Error, Hashable, Sendable {
    /// Texts the gate refused, each with its place. A person fixes them all in one pass.
    case refused([ExportRefusal])
    case noSuchProblem
    case lean(LeanProjectError)
    case folder(String)
    case tool(String)
    case kit(String)
    case changedSinceShown
    case running
    case git(String)
    case patch(HashtagPatchError)
    /// The kit's build did not pass.
    case build(BuildReport)
    /// pdfLaTeX reported errors on the LaTeX file.
    case latex([String])
    case stopped
    case files(String)

    var message: String {
        switch self {
        case .refused(let refusals):
            "Nothing was exported: " + Prose.count(refusals.count, "text") + " cannot be written as LaTeX. "
                + refusals.prefix(5).map(\.message).joined(separator: " ")
                + (refusals.count > 5 ? " And \(refusals.count - 5) more." : "")
        case .noSuchProblem: "The problem is no longer there."
        case .lean(let error): error.message
        case .folder(let reason), .tool(let reason), .kit(let reason), .git(let reason): reason
        case .changedSinceShown: "The problem changed after the export was shown. Look at it again before exporting."
        case .running: "An export of this problem is already running."
        case .patch(let error): error.message
        case .build(let report):
            "The kit's build did not pass, so nothing was written to the folder. "
                + (report.failed.isEmpty ? "" : "Failed: " + report.failed.joined(separator: "; ") + ". ")
                + (report.missing.isEmpty ? "" : "Not reported: " + report.missing.joined(separator: ", ") + ".")
        case .latex(let errors):
            "pdfLaTeX reported errors, so nothing was written: " + errors.prefix(3).joined(separator: " ")
        case .stopped: "The export was stopped. Nothing was written to the folder."
        case .files(let reason): "Writing the export failed: " + reason
        }
    }
}
