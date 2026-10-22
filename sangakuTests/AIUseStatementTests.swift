import Foundation
import Testing
@testable import sangaku

@Suite("AI-use statement (invariant 8)")
struct AIUseStatementTests {
    private let fixture = PreviewFixtures.make()

    private func facts(_ scope: ExportScope = .theoremAndUses) -> AIUseFacts {
        AIUseFacts.make(ExportSnapshot.read(problem: fixture.problem, people: fixture.state.problems.personIDs()),
                        scope: scope)
    }

    private func statement(_ scope: ExportScope = .theoremAndUses) -> AIUseStatement { AIUseStatement.make(facts(scope)) }

    /// Checks steps 5 and 6 of A, closing the open ? on step 5 with a reason.
    private func checkTheRest() throws {
        let reviews = fixture.state.reviews
        let steps = fixture.attemptA.sortedSteps
        let step5 = steps[4], step6 = steps[5]
        let question = try #require(step5.reviews?.first)
        try reviews.resolve(question.stableID, reason: "The parity argument closes it.", alsoCheck: true,
                            revision: try #require(step5.latestRevision?.stableID))
        _ = try reviews.mark(.correct, step: step6.stableID, revision: try #require(step6.latestRevision?.stableID))
    }

    @Test("The example's state: 4 of 6 checked, step 5 objected, the verdict short of steps 3 and 5, only Lem 1 verified")
    func example() {
        #expect(statement().sentences.map(\.markup) == [
            "This statement covers Thm 1 and the 4 statements it uses, directly or through others, with the 6 proof steps they rest on. It is generated from what was recorded for them and says nothing about work not recorded there.",
            "Lem 1, Lem 2, Lem 3 and Lem 4 were first stated by a language model.",
            "A language model drafted the 6 steps.",
            "Steps 3 and 5 were revised afterwards: step 3 by a person and step 5 by a language model.",
            "A language model was asked, in a separate request, to act as a referee on the attempt, and judged it complete. Its verdict covers steps 1, 2, 4 and 6; it does not cover steps 3 and 5, which were revised after it was asked.",
            "4 of the 6 steps were checked by a person, each on its current text.",
            "Step 5 has an open objection from a person, so it does not count as checked.",
            "Step 6 has not been checked by a person.",
            "A language model wrote the Lean code for Lem 1, Lem 2, Lem 3 and Lem 4.",
            "Only Lem 1 is verified in Lean: the Lean code compiles with no sorry and only the standard axioms, and a person confirmed that the Lean statement says what the informal one says.",
            "Lem 2 and Lem 3 compile in Lean with no sorry and only the standard axioms, but no person has yet confirmed their Lean statements.",
            "The Lean code for Lem 4 compiles but is not a complete proof: it uses sorry or an axiom beyond the standard three.",
            "Thm 1 was not checked in Lean.",
            "A computation in GAP found no counterexample to Thm 1 over every group of each order p²q ≤ 100 (15 orders). This is evidence over that scope, not a proof. A person wrote its code.",
            "The steps cite 2 sources: 1 matches a document in zbMATH Open, which shows only that such a document exists; 1 was not found in arXiv or zbMATH Open.",
            "Language models also wrote 8 other messages while this work was discussed; they are not reproduced here.",
        ])
    }

    @Test("Every statement: the refuted claim, and Lem 5 verified too")
    func everyStatement() {
        let text = statement(.everyStatement).sentences.map(\.markup)
        #expect(text.first?.hasPrefix("This statement covers the 10 statements of this problem, with the 6 proof steps") == true)
        #expect(text.contains("Only Lem 1 and Lem 5 are verified in Lean: the Lean code compiles with no sorry and only the standard axioms, and a person confirmed that the Lean statement says what the informal one says."))
        #expect(text.contains("Claim is refuted: a person accepted a refutation of it."))
        #expect(text.contains("Thm 1, Conj, Lem 6 and Lem 7 were not checked in Lean."))
    }

    @Test("\"All\" is said only when every step counts as checked and the attempt finished")
    func allChecked() throws {
        try checkTheRest()
        let all = statement()
        #expect(all.sentences.first { $0.rule == .checked }?.markup == "All 6 steps were checked by a person, each on its current text.")
        #expect(!all.rules.contains(.objections) && !all.rules.contains(.unreviewed))

        fixture.messageA.interrupted = true
        let partial = statement()
        #expect(partial.sentences.first { $0.rule == .checked }?.markup
                == "6 of the 6 steps were checked by a person, each on its current text; the attempt stopped before its end.")
        #expect(partial.sentences.first { $0.rule == .partial }?.markup
                == "The attempt these steps come from stopped before its end, so it is partial.")
        #expect(!partial.markup.contains("All "))
    }

    @Test("A result marked imported is disclosed, with what assumes it")
    func imported() throws {
        let lemma2 = fixture.lemmas[1]
        lemma2.uses = (lemma2.uses ?? []) + [fixture.conjecture]
        try fixture.state.graph.setImported(fixture.conjecture.stableID, source: "Sylow, Theorem 1", in: fixture.problem)
        let text = statement().sentences.map(\.markup)
        #expect(text.first?.hasPrefix("This statement covers Thm 1 and the 5 statements it uses") == true)
        #expect(text.contains("Conj is a result from the literature, cited as \u{201C}Sylow, Theorem 1\u{201D}, and was not checked here; Thm 1, Lem 2 and Lem 3 assume it."))
        #expect(text.contains("Thm 1 and Conj were not checked in Lean."))
    }

    @Test("Every Lean standing short of verified is said, in a set order; verified and unchecked are said apart")
    func leanStandings() {
        #expect(Set(AIUseStatement.leanOrder + [.verified, .notChecked]) == Set(LeanStanding.allCases))
        #expect(AIUseStatement.leanOrder.allSatisfy { AIUseStatement.leanSentence($0, "Lem 1", one: true) != nil })
    }

    @Test("A person's Lean code says when a language model drafted Lean code for the statement; an imported result verified in Lean says so")
    func leanAuthorsAndImported() {
        var facts = AIUseFacts(scope: .everyStatement, theoremLabel: "Thm 1", statementCount: 2, attemptCount: 0)
        facts.lean = [.init(label: "Lem 6", standing: .awaitingFidelity, codeAuthor: .person, modelDrafted: true)]
        facts.imported = [.init(label: "Conj", source: "A, Theorem 2", assumedBy: [], verifiedInLean: true)]
        let text = AIUseStatement.make(facts).sentences.map(\.markup)
        #expect(text.contains("A person wrote the Lean code for Lem 6, after a language model had drafted Lean code for it."))
        #expect(text.contains("Conj is a result from the literature, cited as \u{201C}A, Theorem 2\u{201D}; here it was checked only in Lean, where it is verified."))
    }

    @Test("\"All\" here is ReviewProgress's \"all\" over the same steps")
    func claimsAllAgreesWithProgress() throws {
        let people = fixture.state.problems.personIDs()
        for partial in [false, true] {
            fixture.messageA.interrupted = partial
            let snapshot = ExportSnapshot.read(problem: fixture.problem, people: people)
            let standings = try #require(snapshot.attempts.first?.steps.map(\.standing))
            #expect(AIUseFacts.make(snapshot, scope: .theoremAndUses).claimsAll == ReviewProgress(standings, partial: partial).claimsAll)
        }
    }

    @Test("Paragraphs follow the groups, in order; the clipboard separates them with a blank line")
    func paragraphs() {
        let made = statement()
        #expect(made.paragraphs.map { $0.map(\.rule.paragraph) }.map { Set($0).count } == Array(repeating: 1, count: made.paragraphs.count))
        #expect(made.paragraphs.map { $0[0].rule.paragraph } == [0, 1, 2, 3, 4, 5])
        #expect(made.markup.components(separatedBy: "\n\n").count == made.paragraphs.count)
    }

    @Test("Roles only: no person's, slot's, model's or maker's name")
    func rolesOnly() {
        for scope in [ExportScope.theoremAndUses, .everyStatement] {
            let text = statement(scope).markup
            for name in ["MK", "You", "Model A", "Model B", "Model C", "A's", "B's", "Claude", "Opus", "Anthropic"] {
                #expect(!text.contains(name), "\(scope) names \(name)")
            }
        }
    }

    @Test("The referee: the drafting model judging its own attempt, a gap, an unknown basis")
    func refereeVariants() {
        var facts = AIUseFacts(scope: .theoremAndUses, theoremLabel: "Thm 1", statementCount: 1, attemptCount: 2)
        facts.steps = [AIUseStep(attempt: 1, index: 1), AIUseStep(attempt: 2, index: 1), AIUseStep(attempt: 2, index: 2)]
        facts.draftedByModel = facts.steps
        facts.draftingModels = 2
        facts.unreviewed = facts.steps
        facts.referees = [
            .init(attempt: 1, drafterWasReferee: true, verdict: .complete(covered: [facts.steps[0]], revisedSince: [])),
            .init(attempt: 2, drafterWasReferee: false, verdict: .gap(at: [AIUseStep(attempt: 2, index: 3)], outsideExport: true)),
        ]
        let text = AIUseStatement.make(facts).sentences.map(\.markup)
        #expect(text.contains("Language models drafted the 3 steps."))
        #expect(text.contains("The language model that drafted attempt 1 was then asked, in a separate request, to act as a referee on it, and judged it complete. Its verdict covers step 1 of attempt 1."))
        #expect(text.contains("A language model was asked, in a separate request, to act as a referee on attempt 2, and found a gap at step 3 of attempt 2, not all of which are reproduced here. Its verdict vouches for none of the steps."))
        #expect(text.contains("No step was checked by a person."))
        #expect(text.contains("Step 1 of attempt 1 and steps 1 and 2 of attempt 2 have not been checked by a person."))

        facts.referees = [.init(attempt: 1, drafterWasReferee: false, verdict: .unknownBasis)]
        #expect(AIUseStatement.make(facts).sentences.contains {
            $0.markup.hasSuffix("judged it complete, but when it was asked is not recorded, so its verdict vouches for none of the steps.")
        })
    }

    @Test("Step names group runs and attempts")
    func stepNames() {
        let one = AIUseStatement.Words(attempts: 1)
        #expect(one.steps([.init(attempt: 1, index: 6), .init(attempt: 1, index: 1), .init(attempt: 1, index: 2),
                           .init(attempt: 1, index: 3), .init(attempt: 1, index: 4)]) == "steps 1–4 and 6")
        #expect(one.steps([.init(attempt: 1, index: 5)]) == "step 5")
        #expect(AIUseStatement.Words.runs([1, 2, 4, 6]) == "1, 2, 4 and 6")
    }

    @Test("A computation is evidence over its scope; a model's code says a person started it; a scope stays typeset")
    func computations() {
        var facts = AIUseFacts(scope: .everyStatement, theoremLabel: "Thm 1", statementCount: 2, attemptCount: 0)
        facts.computations = [
            .init(label: "Conj", tool: .sage, scope: "$n \\le 50$", verdict: .counterexample, codeAuthor: .model(ModelSlotID(UUID())),
                  statementRefuted: false),
            .init(label: "Thm 1", tool: .python, scope: " ", verdict: .holds, codeAuthor: .unknown, statementRefuted: false),
        ]
        facts.unfinishedRuns = 2
        let sentences = AIUseStatement.make(facts).sentences.filter { [.computation, .unfinishedRuns].contains($0.rule) }
        #expect(sentences.map(\.markup) == [
            "A computation in Sage reported a counterexample to Conj over $n \\le 50$. No person has accepted it, so it refutes nothing. A language model wrote its code; a person started the run.",
            "A computation in Python found no counterexample to Thm 1; what it covered is not recorded. This is evidence over that scope, not a proof.",
            "2 other runs did not complete or reported nothing conclusive.",
        ])
        #expect(sentences[0].pieces.contains(.prose("$n \\le 50$")), "the scope is a person's prose, typeset")
    }

    @Test("Plain parts never open mathematics: a dollar in a label is escaped")
    func escapesDollars() {
        var facts = AIUseFacts(scope: .everyStatement, theoremLabel: nil, statementCount: 1, attemptCount: 0)
        facts.refuted = ["Claim $x$"]
        #expect(AIUseStatement.make(facts).sentences.last?.markup == "Claim \\$x\\$ is refuted: a person accepted a refutation of it.")
    }

    @Test("Property: every sentence's fact holds, and none overclaims", arguments: 0..<400)
    func gated(seed: Int) {
        var random = SeededGenerator(state: UInt64(seed))
        let facts = Self.randomFacts(&random)
        let made = AIUseStatement.make(facts)
        let text = made.markup
        let rules = Set(made.rules)

        #expect(made.rules.first == .scope)
        #expect(rules.contains(.drafted) == !facts.steps.isEmpty)
        #expect(rules.contains(.checked) == !facts.steps.isEmpty)
        #expect(rules.contains(.partial) == !facts.partialAttempts.isEmpty)
        #expect(rules.contains(.objections) == !facts.objected.isEmpty)
        #expect(rules.contains(.unreviewed) == !facts.unreviewed.isEmpty)
        #expect(rules.contains(.recheck) == !facts.flagged.isEmpty)
        #expect(rules.contains(.referee) == !facts.referees.isEmpty)
        #expect(rules.contains(.refuted) == !facts.refuted.isEmpty)
        #expect(rules.contains(.imported) == !facts.imported.isEmpty)
        #expect(rules.contains(.citations) == (facts.citationsFound + facts.citationsNotFound + facts.citationsUnchecked > 0))
        #expect(rules.contains(.otherMessages) == (facts.otherModelMessages > 0))

        // "All" only with the fact; "verified in Lean" only for statements whose check is rule 2.
        let checkedSentence = made.sentences.first { $0.rule == .checked }?.markup ?? ""
        if facts.claimsAll {
            #expect(checkedSentence.hasPrefix("All ") || checkedSentence.hasPrefix("The one step"))
        } else {
            #expect(!text.contains("All ") && !text.contains("The one step"), "\(text)")
        }
        #expect(text.contains("partial") == !facts.partialAttempts.isEmpty)
        let verified = facts.lean.filter { $0.standing == .verified }
        #expect(text.contains(" verified in Lean") == !verified.isEmpty)
        for word in ["passed", "proved", "proven", "correct", "guarantee"] {
            #expect(!text.lowercased().contains(word), "\(word) in \(text)")
        }
        // Deterministic.
        #expect(AIUseStatement.make(facts) == made)
    }

    private static func randomFacts(_ random: inout SeededGenerator) -> AIUseFacts {
        let attempts = Int.random(in: 0...2, using: &random)
        var facts = AIUseFacts(scope: Bool.random(using: &random) ? .theoremAndUses : .everyStatement,
                               theoremLabel: "Thm 1", statementCount: Int.random(in: 1...5, using: &random),
                               attemptCount: attempts)
        if attempts > 0 {
            facts.steps = (1...attempts).flatMap { attempt in
                (1...Int.random(in: 1...4, using: &random)).map { AIUseStep(attempt: attempt, index: $0) }
            }
        }
        for step in facts.steps {
            switch Int.random(in: 0..<3, using: &random) {
            case 0: facts.checked.append(step)
            case 1: facts.objected.append(step)
            default: facts.unreviewed.append(step)
            }
            switch Int.random(in: 0..<3, using: &random) {
            case 0: facts.draftedByModel.append(step)
            case 1: facts.draftedByPerson.append(step)
            default: facts.draftedByUnknown.append(step)
            }
            if Bool.random(using: &random) { facts.revisedByPerson.append(step) }
            if facts.checked.contains(step), Int.random(in: 0..<4, using: &random) == 0 { facts.flagged.append(step) }
        }
        // Sometimes every step is checked, so "all" is reached.
        if Int.random(in: 0..<3, using: &random) == 0 { facts.checked = facts.steps; facts.objected = []; facts.unreviewed = [] }
        facts.draftingModels = facts.draftedByModel.isEmpty ? 0 : Int.random(in: 1...2, using: &random)
        if attempts > 0, Bool.random(using: &random) { facts.partialAttempts = [Int.random(in: 1...attempts, using: &random)] }
        if attempts > 0, Bool.random(using: &random) {
            facts.referees = [.init(attempt: 1, drafterWasReferee: Bool.random(using: &random),
                                    verdict: Bool.random(using: &random) ? .complete(covered: facts.steps, revisedSince: [])
                                        : .gap(at: [facts.steps[0]], outsideExport: false))]
        }
        let standings: [LeanStanding] = [.verified, .awaitingFidelity, .incomplete, .didNotCompile, .statementDiffers]
        for index in 0..<Int.random(in: 0...3, using: &random) {
            facts.lean.append(.init(label: "Lem \(index + 1)", standing: standings.randomElement(using: &random) ?? .incomplete,
                                    codeAuthor: Bool.random(using: &random) ? .person : .model(ModelSlotID(UUID()))))
        }
        if Bool.random(using: &random) { facts.notInLean = ["Thm 1"] }
        if Bool.random(using: &random) { facts.refuted = ["Claim"] }
        if Bool.random(using: &random) { facts.imported = [.init(label: "Lem 9", source: "A, Theorem 2", assumedBy: ["Thm 1"])] }
        facts.citationsFound = Int.random(in: 0...2, using: &random)
        facts.citationsNotFound = Int.random(in: 0...1, using: &random)
        facts.otherModelMessages = Int.random(in: 0...3, using: &random)
        return facts
    }
}
