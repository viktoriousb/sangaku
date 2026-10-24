import Foundation

/// What exports say about a statement and a step. Roles only, never names (decided for 8b); never more than the
/// statuses say (invariants 3 and 8). Shared by the LaTeX file and the hashtag manuscript.
nonisolated enum ExportWording {
    /// Statuses a person or the app's checks reached here, which no referee outside the app has seen.
    private static let internalStatuses: Set<StatementStatus> = [.modelChecked, .humanChecked, .formallyVerified]

    /// A statement's status as sentences: its status, its steps' progress, why it is held down, what it assumes,
    /// its Lean check and its computations.
    static func status(_ statement: ExportStatement) -> [[ExportPiece]] {
        var sentences: [[ExportPiece]] = []
        sentences.append([.text("Status: " + statusWords(statement.derived.displayed) + ".")])
        if !statement.sources.isEmpty {
            let notes = statement.progress.notes
            sentences.append([.text(statement.progress.headline + (notes.isEmpty ? "" : " (" + notes.joined(separator: ", ") + ")") + ".")])
        }
        for line in statement.explanation.lines { sentences.append([.text(line + ".")]) }
        if let lean = statement.lean {
            var text = "Lean: " + Self.lean(lean.standing) + "."
            if let checked = lean.checkedAt {
                text += " Checked " + day(checked) + " with Lean \(lean.leanVersion), Mathlib \(lean.mathlibRev); code by \(actor(lean.codeAuthor))."
            }
            sentences.append([.text(text)])
        }
        let reported = statement.evidence.filter(\.reported)
        for run in reported { sentences.append(Self.run(run, label: statement.label)) }
        let others = statement.evidence.count - reported.count
        if others > 0 {
            sentences.append([.text(others == 1 ? "One other computation did not complete or reported nothing conclusive."
                                    : "\(others) other computations did not complete or reported nothing conclusive.")])
        }
        return sentences
    }

    /// "checked by a person; checked internally only": a status reached here, which no referee has seen.
    static func statusWords(_ status: StatementStatus) -> String {
        status.words + (internalStatuses.contains(status) ? "; checked internally only" : "")
    }

    /// The short status of the tables and the preface: the status, and the imported results it assumes, since an
    /// import never lowers a status but is always said.
    static func statusWords(_ derived: DerivedStatus, assumed: [String]) -> String {
        statusWords(derived.displayed) + (assumed.isEmpty ? "" : "; assumes " + Prose.list(assumed) + ", imported")
    }

    /// What "verified in Lean" means, wherever it is said: rule 2.
    static let verifiedMeaning = "the Lean code compiles with no sorry and only the standard axioms, and a person confirmed that the Lean statement says what the informal one says"

    /// Where a Lean check stands; "verified" only for `.verified`, which is rule 2 holding.
    static func lean(_ standing: LeanStanding) -> String {
        switch standing {
        case .verified: "verified in Lean (" + verifiedMeaning + ")"
        case .awaitingFidelity: "compiles with no sorry and only the standard axioms; no person has confirmed the Lean statement yet"
        case .incomplete: "the code compiles but uses sorry or an axiom beyond the standard three"
        case .didNotCompile: "the code did not compile"
        case .namesUnusedStatement: "the code names a statement this one does not use, so it does not count"
        case .axiomCheckMissing: "the axiom check did not report, so it does not count"
        case .statementDiffers: "a person found that the Lean statement says something else"
        case .notChecked: "not checked"
        }
    }

    /// One computation, cited by its digest: never its code, never "passed" or "verified".
    static func run(_ run: ExportEvidence, label: String) -> [ExportPiece] {
        let name = ToolID(run.tool).displayName
        let tool = run.toolVersion.hasPrefix(name) ? run.toolVersion
            : name + (run.toolVersion.isEmpty ? "" : " " + run.toolVersion)
        let found = run.verdict == .counterexample ? "reported a counterexample" : "found no counterexample"
        var pieces: [ExportPiece] = [.text("A computation in \(tool), code digest \(run.codeDigest), \(found)")]
        pieces += scope(run.scope)
        pieces.append(.text(run.verdict == .counterexample ? " Only a person can accept it as a refutation." : evidenceNote))
        if let author = codeAuthorNote(run.codeAuthor) { pieces.append(.text(author)) }
        return pieces
    }

    /// " over <scope>.", or that the scope is not recorded.
    static func scope(_ scope: String) -> [ExportPiece] {
        scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [.text("; what it covered is not recorded.")]
            : [.text(" over "), .prose(scope), .text(".")]
    }

    static let evidenceNote = " This is evidence over that scope, not a proof."

    /// Who wrote a computation's code; a model's code ran only on a person's click (invariant 14).
    static func codeAuthorNote(_ author: ExportActor) -> String? {
        switch author {
        case .model: " A language model wrote its code; a person started the run."
        case .person: " A person wrote its code."
        case .unknown: nil
        }
    }

    /// Why a program an export runs did not finish its work: it could not start, was stopped or killed at a limit,
    /// or ended with a status, with the end of what it printed.
    static func failedRun(_ program: String, _ end: RunEnd, output: String) -> String {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = detail.isEmpty ? "." : ": " + String(detail.suffix(400))
        return switch end {
        case .couldNotStart(let reason): program + " could not run: " + reason
        case .timedOut: program + " did not finish in time."
        case .memoryLimit: program + " used more memory than allowed."
        case .diskLimit: program + " wrote more than allowed into its folder."
        case .stopped: program + " was stopped."
        case .signaled(let signal): program + " ended on signal \(signal)" + tail
        case .exited(let code): program + " ended with status \(code)" + tail
        }
    }

    /// The message of the commit an export makes in its folder.
    static func commitMessage(_ kind: ExportKind) -> String {
        switch kind {
        case .latex: "Export the LaTeX file"
        case .hashtag: "Export the hashtag manuscript"
        case .leanProject: "Export the Lean project"
        }
    }

    /// A day as `2026-05-09`, in UTC.
    static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }

    /// Who wrote a step and where it stands, from its revision history and reviews (invariant 7).
    static func provenance(_ step: ExportStep) -> String {
        var parts = ["Written by " + actor(step.drafter)]
        let revisers = step.revisers
        if !revisers.isEmpty { parts.append("revised by " + Prose.list(revisers.map(actor))) }
        let standing = step.standing
        switch standing.human {
        case .checked:
            let people = Set(standing.checks.compactMap(\.reviewerID)).count
            parts.append(people > 1 ? "checked by \(people) people on its current text" : "checked by a person on its current text")
        case .objected:
            parts.append("an objection from a person is open, so it does not count as checked")
        case .unchecked:
            parts.append("not checked by a person")
        }
        if standing.recheck != nil { parts.append("flagged for re-check: an earlier step changed") }
        if !standing.dismissedObjections.isEmpty { parts.append("an earlier objection was dismissed with a reason") }
        switch standing.model {
        case .noVerdict: break
        case .complete: parts.append("covered by the referee model's verdict")
        case .revisedSince: parts.append("revised after the referee model was asked")
        case .gapListed: parts.append("the referee model found a gap here")
        case .attemptHasGap: parts.append("the referee model found a gap elsewhere in the attempt")
        case .unknownBasis: parts.append("the referee model's verdict has no recorded basis")
        }
        switch step.confidence {
        case .delicate: parts.append("marked delicate by its writer")
        case .guess: parts.append("marked a guess by its writer")
        case .standard, .routine: break
        }
        return parts.joined(separator: "; ") + "."
    }

    /// What a citation's check found (invariant 6): a found one shows only that a matching document exists.
    static func citationCheck(_ citation: ExportCitation) -> String {
        switch citation.status {
        case .found: "a matching document was found in " + (citation.indexName ?? "an index")
        case .notFound: "not found in arXiv or zbMATH Open"
        case .unverified: "not checked"
        }
    }

    static func actor(_ actor: ExportActor) -> String {
        switch actor {
        case .person: "a person"
        case .model: "a language model"
        case .unknown: "an author not recorded"
        }
    }

    /// "Steps 3–5 of the attempt." Above a proof's steps.
    static func proofSource(_ indices: [Int], attempt: Int?) -> String {
        let steps = (indices.count == 1 ? "Step " : "Steps ") + AIUseStatement.Words.runs(indices)
        return steps + (attempt.map { " of attempt \($0)" } ?? " of the attempt") + "."
    }
}
