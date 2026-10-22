import Foundation

/// The fact a sentence of the AI-use statement rests on: each sentence is said only when its fact holds.
nonisolated enum AIUseRule: String, CaseIterable, Hashable, Sendable {
    case scope, stated, drafted, revised, partial, referee, checked, objections, unreviewed, recheck
    case leanCode, leanStanding, notInLean, computation, unfinishedRuns, citations, imported, refuted, otherMessages

    /// Sentences are grouped into paragraphs: what it covers, who wrote, who checked, Lean, computations and
    /// citations, and what else the reader must know.
    var paragraph: Int {
        switch self {
        case .scope: 0
        case .stated, .drafted, .revised, .partial: 1
        case .referee, .checked, .objections, .unreviewed, .recheck: 2
        case .leanCode, .leanStanding, .notInLean: 3
        case .computation, .unfinishedRuns, .citations: 4
        case .imported, .refuted, .otherMessages: 5
        }
    }
}

/// Part of a sentence: the app's words and plain labels, or a person's prose that may hold mathematics (a scope).
nonisolated enum ExportPiece: Hashable, Sendable {
    case text(String)
    case prose(String)
}

nonisolated struct AIUseSentence: Hashable, Sendable {
    var rule: AIUseRule
    var pieces: [ExportPiece]

    init(_ rule: AIUseRule, _ pieces: [ExportPiece]) {
        self.rule = rule
        self.pieces = pieces
    }

    init(_ rule: AIUseRule, _ text: String) {
        self.init(rule, [.text(text)])
    }

    /// For `MathText`: plain parts with `$` escaped, prose as written.
    var markup: String {
        pieces.map {
            switch $0 {
            case .text(let text): text.replacingOccurrences(of: "$", with: "\\$")
            case .prose(let prose): prose
            }
        }.joined()
    }
}

/// How language models took part in the work an export holds, generated from provenance and statuses only (invariant
/// 8). Pure and deterministic. It names roles, never a person, a model or a maker; it never says "all" unless every
/// step counts as checked and no attempt stopped early; and "verified" only for a statement whose Lean check is rule 2
/// holding. The same text is shown in Review and written into every export.
nonisolated struct AIUseStatement: Hashable, Sendable {
    var sentences: [AIUseSentence]

    static let heading = "Use of AI"

    /// Its paragraphs, each a run of sentences in the same group, in order.
    var paragraphs: [[AIUseSentence]] {
        var out: [[AIUseSentence]] = []
        for sentence in sentences {
            if let last = out.last?.last, last.rule.paragraph == sentence.rule.paragraph {
                out[out.count - 1].append(sentence)
            } else {
                out.append([sentence])
            }
        }
        return out
    }

    /// Each paragraph's markup, for `MathText`.
    var paragraphMarkups: [String] { paragraphs.map { $0.map(\.markup).joined(separator: " ") } }

    /// For the clipboard: paragraphs separated by a blank line.
    var markup: String { paragraphMarkups.joined(separator: "\n\n") }

    var rules: [AIUseRule] { sentences.map(\.rule) }

    /// The statement for the statements of `scope`.
    static func of(_ snapshot: ExportSnapshot, scope: ExportScope) -> AIUseStatement {
        make(AIUseFacts.make(snapshot, scope: scope))
    }

    static func make(_ facts: AIUseFacts) -> AIUseStatement {
        let words = Words(attempts: facts.attemptCount)
        return AIUseStatement(sentences: [scope(facts)] + authorship(facts, words) + checking(facts, words)
                              + lean(facts) + evidence(facts) + disclosures(facts))
    }

    // MARK: Paragraphs

    /// What it covers.
    private static func scope(_ facts: AIUseFacts) -> AIUseSentence {
        let steps = facts.steps.count
        let covered: String = switch facts.scope {
        case .theoremAndUses:
            (facts.theoremLabel ?? "The theorem") + (facts.statementCount > 1
                ? " and the \(Prose.count(facts.statementCount - 1, "statement")) it uses, directly or through others"
                : "")
        case .everyStatement:
            "the \(Prose.count(facts.statementCount, "statement")) of this problem"
        }
        let stepPart = steps == 0 ? "; no proof step is recorded for them"
            : ", with the \(Prose.count(steps, "proof step")) they rest on"
        return AIUseSentence(.scope, "This statement covers " + covered + stepPart
            + ". It is generated from what was recorded for them and says nothing about work not recorded there.")
    }

    /// Who stated the statements, drafted and revised the steps, and which attempts stopped early.
    private static func authorship(_ facts: AIUseFacts, _ words: Words) -> [AIUseSentence] {
        var out: [AIUseSentence] = []
        let steps = facts.steps.count
        if !facts.statedByModel.isEmpty {
            out.append(AIUseSentence(.stated, Prose.list(facts.statedByModel)
                + (facts.statedByModel.count == 1 ? " was" : " were") + " first stated by a language model."))
        }
        if steps > 0 {
            let model = facts.draftingModels > 1 ? "Language models" : "A language model"
            let text: String
            if facts.draftedByModel.count == steps {
                text = "\(model) drafted the \(Prose.count(steps, "step"))."
            } else if facts.draftedByPerson.count == steps {
                text = "A person wrote the \(Prose.count(steps, "step"))."
            } else {
                var parts: [String] = []
                if !facts.draftedByModel.isEmpty { parts.append("\(model) drafted \(words.steps(facts.draftedByModel))") }
                if !facts.draftedByPerson.isEmpty { parts.append("a person wrote \(words.steps(facts.draftedByPerson))") }
                if !facts.draftedByUnknown.isEmpty {
                    parts.append("who wrote \(words.steps(facts.draftedByUnknown)) is not recorded")
                }
                text = Prose.capitalized(Prose.list(parts)) + "."
            }
            out.append(AIUseSentence(.drafted, text))
        }

        let revised = Array(Set(facts.revisedByPerson + facts.revisedByModel + facts.revisedByUnknown)).sorted()
        if !revised.isEmpty {
            let person = Set(facts.revisedByPerson), model = Set(facts.revisedByModel), unknown = Set(facts.revisedByUnknown)
            let groups = [
                (revised.filter { person.contains($0) && !model.contains($0) }, "by a person"),
                (revised.filter { model.contains($0) && !person.contains($0) }, "by a language model"),
                (revised.filter { person.contains($0) && model.contains($0) }, "by a person and by a language model"),
                (revised.filter { unknown.contains($0) && !person.contains($0) && !model.contains($0) },
                 "by someone not recorded"),
            ].filter { !$0.0.isEmpty }.map { (steps: $0.0, by: $0.1) }
            let subject = Prose.capitalized(words.steps(revised)) + (revised.count == 1 ? " was" : " were")
            let text = groups.count == 1
                ? subject + " revised afterwards " + groups[0].by + "."
                : subject + " revised afterwards: " + Prose.list(groups.map { words.steps($0.steps) + " " + $0.by }) + "."
            out.append(AIUseSentence(.revised, text))
        }

        if !facts.partialAttempts.isEmpty {
            let text = if facts.attemptCount == 1 {
                "The attempt these steps come from stopped before its end, so it is partial."
            } else if facts.partialAttempts.count == 1 {
                "Attempt \(facts.partialAttempts[0]) stopped before its end, so it is partial."
            } else {
                "Attempts \(Prose.list(facts.partialAttempts.map(String.init))) stopped before their end, so they are partial."
            }
            out.append(AIUseSentence(.partial, text))
        }
        return out
    }

    /// The referee's verdicts and where each step stands with people.
    private static func checking(_ facts: AIUseFacts, _ words: Words) -> [AIUseSentence] {
        var out = facts.referees.map { referee(facts, $0, words) }
        let steps = facts.steps.count
        if steps > 0 {
            let count: String = if facts.claimsAll {
                steps == 1 ? "The one step was" : "All \(steps) steps were"
            } else if facts.checked.isEmpty {
                "No step was"
            } else {
                "\(facts.checked.count) of the \(Prose.count(steps, "step")) " + (facts.checked.count == 1 ? "was" : "were")
            }
            let partial = facts.partialAttempts.isEmpty ? ""
                : "; " + (facts.attemptCount == 1 ? ReviewProgress.partialClause : "an attempt they come from stopped before its end")
            let each = facts.checked.isEmpty ? "" : facts.checked.count == 1 ? ", on its current text" : ", each on its current text"
            out.append(AIUseSentence(.checked, count + " checked by a person" + each + partial + "."))
        }
        if !facts.objected.isEmpty {
            let one = facts.objected.count == 1
            out.append(AIUseSentence(.objections, Prose.capitalized(words.steps(facts.objected))
                + (one ? " has an open objection from a person, so it does not count as checked."
                       : " have open objections from a person, so they do not count as checked.")))
        }
        if !facts.unreviewed.isEmpty {
            out.append(AIUseSentence(.unreviewed, Prose.capitalized(words.steps(facts.unreviewed))
                + (facts.unreviewed.count == 1 ? " has" : " have") + " not been checked by a person."))
        }
        if !facts.flagged.isEmpty {
            let one = facts.flagged.count == 1
            out.append(AIUseSentence(.recheck, Prose.capitalized(words.steps(facts.flagged))
                + (one ? " is" : " are") + " flagged for re-check: an earlier step changed what it establishes after "
                + (one ? "it was" : "they were") + " checked."))
        }
        return out
    }

    private static func referee(_ facts: AIUseFacts, _ referee: AIUseFacts.Referee, _ words: Words) -> AIUseSentence {
        let attempt = facts.attemptCount == 1 ? "the attempt" : "attempt \(referee.attempt)"
        let asked = referee.drafterWasReferee
            ? "The language model that drafted \(attempt) was then asked, in a separate request, to act as a referee on it"
            : "A language model was asked, in a separate request, to act as a referee on \(attempt)"
        let text: String
        switch referee.verdict {
        case .complete(let covered, let revisedSince):
            let coverage: String = if revisedSince.isEmpty {
                "Its verdict covers \(words.steps(covered))."
            } else if covered.isEmpty {
                "Its verdict covers none of the steps as they now read: each was revised after it was asked."
            } else {
                "Its verdict covers \(words.steps(covered)); it does not cover \(words.steps(revisedSince)), which \(revisedSince.count == 1 ? "was" : "were") revised after it was asked."
            }
            text = asked + ", and judged it complete. " + coverage
        case .gap(let at, let outside):
            let place: String = if at.isEmpty {
                "found a gap"
            } else {
                "found a gap at \(words.steps(at))" + (outside ? ", not all of which are reproduced here" : "")
            }
            text = asked + ", and " + place + ". Its verdict vouches for none of the steps."
        case .unknownBasis:
            text = asked + ", and judged it complete, but when it was asked is not recorded, so its verdict vouches for none of the steps."
        }
        return AIUseSentence(.referee, text)
    }

    /// Who wrote the Lean code, then where each check stands. "Verified" only for `.verified`, which is rule 2.
    private static func lean(_ facts: AIUseFacts) -> [AIUseSentence] {
        var out: [AIUseSentence] = []
        let byModel = facts.lean.filter { $0.codeAuthor.isModel }.map(\.label)
        let byPerson = facts.lean.filter { $0.codeAuthor == .person && !$0.modelDrafted }.map(\.label)
        let byPersonAfterModel = facts.lean.filter { $0.codeAuthor == .person && $0.modelDrafted }.map(\.label)
        var authors: [String] = []
        if !byModel.isEmpty { authors.append("a language model wrote the Lean code for " + Prose.list(byModel)) }
        if !byPerson.isEmpty { authors.append("a person wrote the Lean code for " + Prose.list(byPerson)) }
        if !byPersonAfterModel.isEmpty {
            authors.append("a person wrote the Lean code for " + Prose.list(byPersonAfterModel)
                           + ", after a language model had drafted Lean code for " + (byPersonAfterModel.count == 1 ? "it" : "them"))
        }
        if !authors.isEmpty { out.append(AIUseSentence(.leanCode, Prose.capitalized(Prose.list(authors)) + ".")) }

        func labels(_ standing: LeanStanding) -> [String] { facts.lean.filter { $0.standing == standing }.map(\.label) }
        let verified = labels(.verified)
        if !verified.isEmpty {
            let one = verified.count == 1
            let only = verified.count < facts.lean.count + facts.notInLean.count ? "Only " : ""
            out.append(AIUseSentence(.leanStanding, only + Prose.list(verified) + (one ? " is" : " are")
                + " verified in Lean: " + ExportWording.verifiedMeaning + "."))
        }
        for standing in leanOrder {
            let found = labels(standing)
            if let sentence = leanSentence(standing, Prose.list(found), one: found.count == 1), !found.isEmpty {
                out.append(AIUseSentence(.leanStanding, sentence))
            }
        }
        if facts.lean.isEmpty, !facts.notInLean.isEmpty {
            out.append(AIUseSentence(.notInLean, "No statement was checked in Lean."))
        } else if !facts.notInLean.isEmpty {
            out.append(AIUseSentence(.notInLean, Prose.list(facts.notInLean)
                + (facts.notInLean.count == 1 ? " was" : " were") + " not checked in Lean."))
        }
        return out
    }

    /// The order the standings short of verified are said in, from nearest to it.
    static let leanOrder: [LeanStanding] = [.awaitingFidelity, .incomplete, .didNotCompile, .namesUnusedStatement,
                                            .axiomCheckMissing, .statementDiffers]

    /// One standing short of verified, for `list`. Every standing is named, so a new one cannot go unsaid.
    static func leanSentence(_ standing: LeanStanding, _ list: String, one: Bool) -> String? {
        switch standing {
        case .verified, .notChecked: nil
        case .awaitingFidelity:
            "\(list) \(one ? "compiles" : "compile") in Lean with no sorry and only the standard axioms, but no person has yet confirmed \(one ? "its Lean statement" : "their Lean statements")."
        case .incomplete:
            "The Lean code for \(list) compiles but is not a complete proof: it uses sorry or an axiom beyond the standard three."
        case .didNotCompile:
            "The Lean code for \(list) did not compile."
        case .namesUnusedStatement:
            "The Lean code for \(list) names a statement \(one ? "it does" : "they do") not use, so it does not count."
        case .axiomCheckMissing:
            "For \(list), Lean's axiom check did not report, so \(one ? "it does" : "they do") not count as verified."
        case .statementDiffers:
            "For \(list), a person found that the Lean statement says something other than the informal one."
        }
    }

    /// Computations and citations.
    private static func evidence(_ facts: AIUseFacts) -> [AIUseSentence] {
        var out: [AIUseSentence] = []
        for run in facts.computations {
            let tool = ToolID(run.tool).displayName
            var pieces: [ExportPiece] = [.text(run.verdict == .counterexample
                ? "A computation in \(tool) reported a counterexample to \(run.label)"
                : "A computation in \(tool) found no counterexample to \(run.label)")]
            pieces += ExportWording.scope(run.scope)
            if run.verdict == .counterexample {
                if !run.statementRefuted { pieces.append(.text(" No person has accepted it, so it refutes nothing.")) }
            } else {
                pieces.append(.text(ExportWording.evidenceNote))
            }
            if let author = ExportWording.codeAuthorNote(run.codeAuthor) { pieces.append(.text(author)) }
            out.append(AIUseSentence(.computation, pieces))
        }
        if facts.unfinishedRuns > 0 {
            let one = facts.unfinishedRuns == 1
            out.append(AIUseSentence(.unfinishedRuns, (one ? "One other run" : "\(facts.unfinishedRuns) other runs")
                + " did not complete or reported nothing conclusive."))
        }

        let citations = facts.citationsFound + facts.citationsNotFound + facts.citationsUnchecked
        if citations > 0 {
            var parts: [String] = []
            if facts.citationsFound > 0 {
                let index = facts.foundIn.isEmpty ? "arXiv or zbMATH Open" : Prose.list(facts.foundIn)
                parts.append("\(facts.citationsFound) \(facts.citationsFound == 1 ? "matches" : "match") a document in \(index), which shows only that such a document exists")
            }
            if facts.citationsNotFound > 0 {
                parts.append("\(facts.citationsNotFound) \(facts.citationsNotFound == 1 ? "was" : "were") not found in arXiv or zbMATH Open")
            }
            if facts.citationsUnchecked > 0 {
                parts.append("\(facts.citationsUnchecked) \(facts.citationsUnchecked == 1 ? "is" : "are") unchecked")
            }
            out.append(AIUseSentence(.citations, "The steps cite \(Prose.count(citations, "source")): "
                + parts.joined(separator: "; ") + "."))
        }
        return out
    }

    /// Imported and refuted statements, and the language models' other messages.
    private static func disclosures(_ facts: AIUseFacts) -> [AIUseSentence] {
        var out: [AIUseSentence] = []
        for result in facts.imported {
            let assumed = result.assumedBy.isEmpty ? ""
                : "; " + Prose.list(result.assumedBy) + (result.assumedBy.count == 1 ? " assumes" : " assume") + " it"
            let checked = result.verifiedInLean ? "; here it was checked only in Lean, where it is verified"
                : ", and was not checked here"
            out.append(AIUseSentence(.imported, result.label + " is a result from the literature, cited as \u{201C}"
                + result.source + "\u{201D}" + checked + assumed + "."))
        }
        if !facts.refuted.isEmpty {
            let one = facts.refuted.count == 1
            out.append(AIUseSentence(.refuted, Prose.list(facts.refuted) + (one ? " is" : " are")
                + " refuted: a person accepted a refutation of " + (one ? "it." : "each.")))
        }
        if facts.otherModelMessages > 0 {
            let one = facts.otherModelMessages == 1
            out.append(AIUseSentence(.otherMessages, "Language models also wrote "
                + (one ? "one other message" : "\(facts.otherModelMessages) other messages")
                + " while this work was discussed; " + (one ? "it is" : "they are") + " not reproduced here."))
        }
        return out
    }

    /// Step names: "step 5", "steps 1–4 and 6", "steps 3 and 5 of attempt 1 and step 2 of attempt 2".
    nonisolated struct Words {
        var attempts: Int

        func steps(_ steps: [AIUseStep]) -> String {
            let groups = Dictionary(grouping: Set(steps), by: \.attempt).sorted { $0.key < $1.key }
            return Prose.list(groups.map { attempt, members in
                let indices = members.map(\.index).sorted()
                return (indices.count == 1 ? "step " : "steps ") + Self.runs(indices)
                    + (attempts > 1 ? " of attempt \(attempt)" : "")
            })
        }

        /// "1, 2, 4 and 6"; a run of three or more as "1–4".
        static func runs(_ indices: [Int]) -> String {
            var runs: [(first: Int, last: Int)] = []
            for index in indices {
                if let run = runs.last, run.last < Int.max, index == run.last + 1 {
                    runs[runs.count - 1].last = index
                } else {
                    runs.append((index, index))
                }
            }
            return Prose.list(runs.flatMap { run in
                run.last - run.first >= 2 ? ["\(run.first)–\(run.last)"] : (run.first...run.last).map(String.init)
            })
        }
    }
}
