#if DEBUG
import Foundation
import SwiftData
import SwiftUI

/// The mockups' example, so previews and tests show real math: Theorem 1 (a group of order p²q has a normal
/// Sylow subgroup), Model A's and Model B's attempts, Referee C, the review state, Lean results, the GAP
/// sweep, dead ends and citations. Debug builds only.
enum PreviewFixtures {
    struct Handles {
        let state: AppState
        let problem: Problem
        let you: Person
        let mk: Person
        let slotA: ModelSlot
        let slotB: ModelSlot
        let slotC: ModelSlot
        let attemptA: ProofAttempt
        let attemptB: ProofAttempt
        let theorem: Statement
        let lemmas: [Statement]
        let refutedClaim: Statement
        let conjecture: Statement
        /// Lem 5: verified in Lean, but uses Lem 3 and Lem 4, so it shows "checked by a model" (invariant 13).
        let cappedLemma: Statement
        /// Lem 6: checked by a person, but uses the refuted Claim, so it shows "sketched".
        let onRefutedClaim: Statement
        /// Lem 7: uses Lem 6, so it depends on the refuted Claim through it.
        let belowRefuted: Statement
        let mainBranch: Branch
        /// A plain question to A, A's complete reply (with its request record), a stopped reply and a failed one.
        let question: Message
        let reply: Message
        let interruptedReply: Message
        let failedReply: Message
        let fanOutPrompt: Message
        let fanOut: FanOut
        let messageA: Message
        let messageB: Message
        let refereeMessage: Message
        /// A and B compared by C at 11:16, after steps 3 and 5 were revised: rows 1–4 equivalent, row 5 diverging,
        /// step 6 only in A. Which of A and B is "Attempt 1" follows their IDs (`SideOrder`).
        let alignment: Alignment
        /// A dead end explored with A (its reason written by You from A's reply), a dead end where B made an
        /// attempt, a parked branch with MK's note, and a fork from A's attempt made inside the fan-out, so B's attempt
        /// and the referee's pass are not part of it. A is adopted: its steps are Theorem 1's proof.
        let classEquation: Branch
        let deadEndReply: Message
        let induction: Branch
        let inductionAttempt: ProofAttempt
        let parked: Branch
        let fork: Branch
        let forkReply: Message

        var mathContext: MathContext { state.problems.mathContext(for: problem) }

        /// Sends a message on the main branch shortly after launch (`-SangakuDemoSend`), to A alone, or as a
        /// fan-out to A and B refereed by C (`-SangakuDemoFanOut`).
        func scheduleSend(_ text: String, fanOut visibility: FanOutVisibility? = nil) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [state, problem, mainBranch, slotA, slotB, slotC] in
                MainActor.assumeIsolated {
                    let draft = state.threads.draft(for: mainBranch.stableID)
                    draft.text = text
                    if let visibility {
                        draft.selection = SendSelection(recipients: [slotA.stableID, slotB.stableID],
                                                        visibility: visibility, refereeSlotID: slotC.stableID)
                    }
                    try? state.threads.send(problem: problem, branch: mainBranch, draft: draft)
                }
            }
        }
    }

    /// Where the fixture's requests go. The example itself is always in memory: nothing is saved.
    enum Services: Equatable {
        /// No network and no Keychain: a send fails visibly (tests, previews, `-SangakuFixture YES`).
        case offline
        /// A canned answer streamed in the wire format, with a placeholder key in memory
        /// (`-SangakuFixture YES -SangakuDemoReplies YES`).
        case demo
        /// The real Keychain and network (`-SangakuFixtureLive YES`): real requests to the provider about the
        /// example problem, with the key stored in Settings. Each one is billed; none is kept after quitting.
        case live

        /// From the launch arguments; nil when no fixture is asked for. `-SangakuFixtureVerified YES` asks for the
        /// verification example, on its own or with the others.
        static func from(arguments: [String]) -> Services? {
            if arguments.contains("-SangakuFixtureLive") { return .live }
            guard arguments.contains("-SangakuFixture") || arguments.contains("-SangakuFixtureVerified") else { return nil }
            return arguments.contains("-SangakuDemoReplies") ? .demo : .offline
        }
    }

    /// `demoPause` is the demo stream's pause between events; tests set it to zero.
    static func make(services: Services = .offline, demoPause: Duration = .milliseconds(45)) -> Handles {
        let state = switch services {
        case .offline:
            AppState(storage: .inMemory)
        case .demo:
            AppState(storage: .inMemory, secrets: InMemorySecretStore([AnthropicProvider.keyAccount: "demo"]),
                     transport: DemoTransport(pause: demoPause))
        case .live:
            AppState(storage: .inMemory, secrets: KeychainSecretStore(), transport: URLSessionTransport.standard())
        }
        let context = state.container.mainContext
        let manager = state.problems

        // People and models
        let you = manager.me()
        let mk = Person(name: "MK", initials: "MK")
        context.insert(mk)
        let slotA = slot("A", .prover, .modelA, ModelCatalog.claudeOpus55.id)
        let slotB = slot("B", .prover, .modelB, ModelCatalog.claudeOpus55.id)
        let slotC = slot("C", .referee, .modelC, ModelCatalog.claudeOpus55.id)
        let byA = Author.model(slotA.slotID), byB = Author.model(slotB.slotID), byC = Author.model(slotC.slotID)
        let byYou = Author.human(you.personID)

        // The problem and its notation
        let problem = manager.createProblem(
            title: #"Normal Sylow subgroups, $|G| = p^2q$"#,
            statementLaTeX: #"Let $p \neq q$ be primes and let $G$ be a group of order $p^2 q$. Then $G$ has a normal Sylow subgroup."#)
        problem.allowedProviderIDs = ["anthropic"]
        problem.modelSlots = [slotA, slotB, slotC]
        for (symbol, meaning, macro) in [
            ("G", #"a finite group, $|G| = p^2q$"#, nil),
            ("p, q", "distinct primes", nil),
            ("n_r", #"number of Sylow $r$-subgroups"#, nil),
            (#"\Syl_r(G)"#, #"the set of Sylow $r$-subgroups"#, #"\DeclareMathOperator{\Syl}{Syl}"#),
        ] {
            _ = try? manager.addConvention(to: problem, symbolLaTeX: symbol, meaning: meaning, macroDefinition: macro)
        }

        // Branches, at fixed times so they always sort main first. Their messages are written while they are live;
        // they are retired at the end, as a person would.
        let main = problem.sortedBranches[0]
        main.name = "Counting elements"
        main.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 - 7_200)
        let classEquation = Branch(name: "Class equation")
        classEquation.reason = #"The class equation constrains centralizer sizes, not $n_q$. Without control of $Z(G)$ the case split never closed, and every route fell back on the Sylow counts anyway."#
        classEquation.reasonForModels = "Tried: class equation alone. Stalls on |Z(G)|. Don't retry without new input on the center."
        let induction = Branch(name: "Induction on |G|")
        induction.reason = "Passing to a quotient loses the order p²q shape, so the induction hypothesis never applies."
        induction.reasonForModels = "Tried: induction on |G|. Quotients leave the p²q family."
        let complement = Branch(name: "Normal p-complement")
        complement.reason = "Burnside's transfer theorem gives a normal p-complement when a Sylow p-subgroup is central in its normalizer. That hypothesis doesn't hold in general here. MK: revisit for p²q²."
        for (offset, branch) in [classEquation, induction, complement].enumerated() {
            branch.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + 950 + Double(offset) * 10)
        }
        problem.branches = (problem.branches ?? []) + [classEquation, induction, complement]

        // The fan-out: You ask A and B, independently; C referees.
        let prompt = Message(author: byYou, bodyLaTeX: "@A @B prove Theorem 1 independently. @C referee both once they finish.", kind: .prompt)
        let fanOut = FanOut(visibility: .independent)
        fanOut.refereeSlotID = slotC.stableID
        prompt.fanOut = fanOut

        let attemptA = attempt(author: byA, at: 150, steps: [
            (#"$n_p \in \{1, q\}$, $n_p \equiv 1 \pmod{p}$; $n_q \in \{1, p, p^2\}$, $n_q \equiv 1 \pmod{q}$."#, "Sylow counts", .standard),
            (#"If neither Sylow subgroup is normal, then $n_p = q$, so $q \equiv 1 \pmod{p}$ and in particular $q > p$."#, "q > p", .routine),
            (#"$n_q = p$ would need $p \equiv 1 \pmod{q}$, impossible since $1 < p < q$. Hence $n_q = p^2$."#, "n_q = p^2", .routine),
            (#"So $q \mid p^2 - 1 = (p - 1)(p + 1)$. As $0 < p - 1 < q$, $q \nmid p - 1$, hence $q \mid p + 1$."#, "q | p + 1", .routine),
            (#"$q \mid p + 1$ with $q > p$ forces $q = p + 1$, so $(p, q) = (2, 3)$ and $|G| = 12$."#, "Resolve q | p + 1", .delicate),
            (#"If $|G| = 12$ and $n_3 = 4$, the four Sylow $3$-subgroups meet pairwise trivially and contribute $8$ elements of order $3$. The remaining $4$ elements form the unique Sylow $2$-subgroup, which is therefore normal."#, "Order 12 case", .routine),
        ])
        let attemptB = attempt(author: byB, at: 160, steps: [
            (#"By Sylow, $n_p$ divides $q$ with $n_p \equiv 1 \pmod{p}$, and $n_q$ divides $p^2$ with $n_q \equiv 1 \pmod{q}$."#, "Sylow counts", .standard),
            (#"Assume no Sylow subgroup is normal. Then $n_p = q$, so $p \mid q - 1$, giving $q > p$."#, "q > p", .routine),
            (#"Since $1 < p < q$, $p \not\equiv 1 \pmod{q}$, so $n_q \neq p$. Hence $n_q = p^2$."#, "n_q = p^2", .routine),
            (#"$p^2 \equiv 1 \pmod{q}$ and $0 < p - 1 < q$, so $q$ must divide $p + 1$."#, "q | p + 1", .routine),
            (#"Since $q > p$, $q$ cannot divide $p + 1$. This contradicts step 4, so some Sylow subgroup is normal."#, "Resolve q | p + 1", .routine),
        ])
        fanOut.attempts = [attemptA, attemptB]
        let messageA = Message(author: byA, kind: .attempt)
        messageA.proofAttempt = attemptA
        let messageB = Message(author: byB, kind: .attempt)
        messageB.proofAttempt = attemptB

        messageA.derivedFromIDs = [prompt.stableID]
        messageB.derivedFromIDs = [prompt.stableID]
        main.messages = [prompt, messageA, messageB]
        for (offset, message) in [prompt, messageA, messageB].enumerated() {
            message.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(offset) * 60)
        }
        // Each attempt's record holds the context it was sent, built while both attempts were still running.
        for (message, slot, attempt) in [(messageA, slotA, attemptA), (messageB, slotB, attemptB)] {
            message.request = structuredRecord(
                state: state, problem: problem, branch: main, slot: slot,
                purpose: .reply(slot: slot.slotID, fanOut: fanOut.stableID), live: [messageA.stableID, messageB.stableID],
                at: prompt.createdAt, finished: message.createdAt,
                output: DemoOutput.attempt(overview: "", steps: attempt.sortedSteps.map { ($0.establishes, $0.confidence, $0.textLaTeX) }),
                usage: TokenUsage(input: 2_390, cacheWrite: 0, cacheRead: 0, output: message === messageA ? 4_210 : 3_655))
        }

        let summary = #"A's proof is complete. B's step 5 is false: $q \mid p + 1$ with $q > p$ allows $q = p + 1$, which happens exactly when $(p, q) = (2, 3)$, the case A treats in step 6."#
        let refereeMessage = Message(author: byC, bodyLaTeX: summary, kind: .referee)
        refereeMessage.derivedFromIDs = [prompt.stableID, messageA.stableID, messageB.stableID]
        refereeMessage.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + 180)
        let verdictA = RefereeVerdict(outcome: .complete, rationale: "A's proof is complete as written. Its one delicate inference is step 5, which I'd still check by hand.")
        let verdictB = RefereeVerdict(outcome: .gap, gapStepIndices: [5], rationale: #"B's step 5 is false: $q \mid p + 1$ with $q > p$ allows $q = p + 1$, which happens exactly when $(p, q) = (2, 3)$."#)
        for verdict in [verdictA, verdictB] {
            verdict.refereeSlotID = slotC.stableID
            verdict.messageID = refereeMessage.stableID
            verdict.requestedAt = refereeMessage.createdAt
            verdict.createdAt = refereeMessage.createdAt.addingTimeInterval(40)
        }
        verdictA.attempt = attemptA
        verdictB.attempt = attemptB
        fanOut.verdicts = [verdictA, verdictB]
        main.messages = (main.messages ?? []) + [refereeMessage]
        refereeMessage.request = structuredRecord(
            state: state, problem: problem, branch: main, slot: slotC, purpose: .referee(slot: slotC.slotID, fanOut: fanOut.stableID),
            live: [refereeMessage.stableID], at: refereeMessage.createdAt, finished: refereeMessage.createdAt.addingTimeInterval(40),
            output: DemoOutput.referee(summary: summary, verdicts: [("A", .complete, [], verdictA.rationale),
                                                                    ("B", .gap, [5], verdictB.rationale)]),
            usage: TokenUsage(input: 9_120, cacheWrite: 0, cacheRead: 0, output: 2_840))

        // You wrote the GAP sweep after reading A's attempt, and ran it (the run is recorded below).
        let sweep = Message(author: byYou, bodyLaTeX: "", kind: .compute)
        sweep.derivedFromIDs = [messageA.stableID]
        sweep.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + 240)
        let sweepCell = ComputeCell(tool: .gap, code: gapSweepCode, scope: "every group of each order p²q ≤ 100 (15 orders)",
                                    claim: "Every group of order $p^2 q$ has a normal Sylow subgroup.")
        sweepCell.createdAt = sweep.createdAt
        sweep.computeCell = sweepCell
        main.messages = (main.messages ?? []) + [sweep]

        // Review state, on the morning after the fan-out: steps 1–4 checked (step 2 by MK), step 5 open ?, step 6
        // unchecked. 4 of 6. Steps 3 and 5 were revised after the referee's pass, so its verdict no longer covers
        // them (rule 4).
        let stepsA = attemptA.sortedSteps
        func check(_ step: Step, by person: Person, at time: Date) {
            let review = Review(reviewer: person.personID, verdict: .correct, revisionReviewedID: step.latestRevision?.stableID)
            review.createdAt = time
            step.reviews = (step.reviews ?? []) + [review]
        }
        check(stepsA[0], by: you, at: day(11, 2))
        check(stepsA[1], by: mk, at: day(11, 4))
        // You tidied the wording of step 3 (what it establishes is unchanged), then checked the new version.
        revise(stepsA[2], by: byYou, at: day(11, 5),
               text: #"$n_q = p$ would need $p \equiv 1 \pmod{q}$, which is impossible because $1 < p < q$. Hence $n_q = p^2$."#)
        check(stepsA[2], by: you, at: day(11, 6))
        check(stepsA[3], by: you, at: day(11, 7))

        // Step 5: You asked for the parity argument, A revised the step, and You's ? on the revision is still open.
        let step5 = stepsA[4]
        let firstVersion = step5.latestRevision
        let jump = StepComment(author: byYou, body: "This jumps from q = p + 1 to (2, 3) without saying why. Spell it out.",
                               revisionID: firstVersion?.stableID)
        jump.createdAt = day(11, 5)
        let revised = revise(step5, by: byA, at: day(11, 12),
                             text: #"Since $q \mid p + 1$ and $q > p$, we get $q = p + 1$. Of two consecutive integers greater than $2$ one is even, so the primes $p, q$ must be $2, 3$, and $|G| = 12$."#)
        let question = Review(reviewer: you.personID, verdict: .unclear, revisionReviewedID: revised.stableID)
        question.createdAt = day(11, 14)
        step5.reviews = [question]
        let parity = StepComment(author: byYou, body: "Does the parity argument close it?", revisionID: revised.stableID)
        parity.createdAt = day(11, 15)
        step5.comments = [jump, parity]

        // C's alignment of A and B, made after the revisions above, so every row covers the current text.
        let alignment = alignment(attemptA, attemptB, by: slotC, at: day(11, 16))
        problem.alignments = [alignment]
        stepsA[0].citations = [Citation(rawText: "Dummit & Foote, Abstract Algebra, 3rd ed., §4.5", status: .found)]
        stepsA[0].citations?.first?.indexName = "zbMATH Open"
        stepsA[5].citations = [Citation(rawText: "Kessler & Varga (2019), J. Algebra, Lemma 2.4", status: .notFound)]

        // Statements. The theorem came with the problem.
        let theorem = manager.ensurePinnedTheorem(for: problem)
        let lemma1 = Statement(kind: .lemma, label: "Lem 1", statementLaTeX: #"$n_p \in \{1, q\}$ with $n_p \equiv 1 \pmod{p}$, and $n_q \in \{1, p, p^2\}$ with $n_q \equiv 1 \pmod{q}$."#, author: byA)
        let lemma2 = Statement(kind: .lemma, label: "Lem 2", statementLaTeX: #"If neither Sylow subgroup is normal, then $q > p$."#, author: byA)
        let lemma3 = Statement(kind: .lemma, label: "Lem 3", statementLaTeX: #"If $n_p = q$ and $n_q = p^2$, then $(p, q) = (2, 3)$."#, author: byA)
        let lemma4 = Statement(kind: .lemma, label: "Lem 4", statementLaTeX: #"A group of order $12$ with $n_3 = 4$ has a normal Sylow $2$-subgroup."#, author: byA)
        let refuted = Statement(kind: .claim, label: "Claim", statementLaTeX: #"$n_q = p$ is possible."#, author: byB)
        refuted.refutationNote = #"$n_q = p$ needs $p \equiv 1 \pmod{q}$, impossible since $p < q$."#
        refuted.refutationAcceptedByID = you.stableID
        refuted.refutationAcceptedAt = day(11, 40)
        let conjecture = Statement(kind: .conjecture, label: "Conj", statementLaTeX: #"If $|G| = p^2 q^2$, then $G$ has a normal Sylow subgroup."#, author: byYou)
        // Promoted by people after the referee's pass, to show the cap at work.
        let lemma5 = Statement(kind: .lemma, label: "Lem 5", statementLaTeX: #"The case $n_p = q$, $n_q = p^2$ does not occur."#, author: Author.human(mk.personID))
        let lemma6 = Statement(kind: .lemma, label: "Lem 6", statementLaTeX: #"If $n_q = p$, then $q \mid p - 1$."#, author: byYou)
        let lemma7 = Statement(kind: .lemma, label: "Lem 7", statementLaTeX: #"$n_q = p$ contradicts $q > p$."#, author: byYou)
        let statements = [theorem, lemma1, lemma2, lemma3, lemma4, refuted, conjecture, lemma5, lemma6, lemma7]
        // Fixed times, so the order statements are read and sent in is the same on every run.
        for (offset, statement) in statements.enumerated() {
            statement.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + 300 + Double(offset))
        }
        problem.statements = statements

        theorem.sourceSteps = stepsA
        lemma1.sourceSteps = [stepsA[0]]
        lemma2.sourceSteps = [stepsA[1]]
        lemma3.sourceSteps = Array(stepsA[2...4])
        lemma4.sourceSteps = [stepsA[5]]
        theorem.uses = [lemma1, lemma2, lemma3, lemma4]
        lemma3.uses = [lemma1, lemma2]
        lemma5.uses = [lemma3, lemma4]
        lemma6.sourceSteps = [stepsA[2]]
        lemma6.uses = [refuted]
        lemma7.sourceSteps = [stepsA[2]]
        lemma7.uses = [lemma6]

        // Lean checks of the morning after, in one module: Lem 1–3 and 5 with standard axioms, Lem 4 with a sorry.
        let standard = ["propext", "Classical.choice", "Quot.sound"]
        let checks: [(Statement, LeanSource, [String], [LeanMessage])] = [
            (lemma1, LeanFixtureCode.lemma1, standard, []), (lemma2, LeanFixtureCode.lemma2, standard, []),
            (lemma3, LeanFixtureCode.lemma3, standard, []),
            (lemma4, LeanFixtureCode.lemma4, standard + ["sorryAx"],
             [LeanMessage(severity: "warning", line: 1, column: 8, text: "declaration uses 'sorry'", kind: "hasSorry")]),
            (lemma5, LeanFixtureCode.lemma5, standard, []),
        ]
        let module = LeanModulePlan(checks.map { ($0.0.stableID, $0.1) }).digest
        for (offset, (statement, source, axioms, messages)) in checks.enumerated() {
            let result = LeanResult()
            result.createdAt = day(11, 30)
            result.record(.fixture(statementID: statement.stableID, source: source, axioms: axioms, messages: messages),
                          module: module, environment: LeanFixtureCode.environment, checkedBy: you.stableID,
                          sourceAuthor: byA, draftMessageID: nil, duration: 41 + Double(offset), at: day(11, 30))
            statement.leanResult = result
        }
        lemma1.fidelityReviews = [fidelity(lemma1, by: you, at: day(11, 32))]
        lemma5.fidelityReviews = [fidelity(lemma5, by: mk, at: day(11, 33))]

        // You ran the GAP sweep the evening of the fan-out.
        let sweepRun = Evidence(tool: .gap, code: gapSweepCode, output: "true", passed: true,
                                scope: "every group of each order p²q ≤ 100 (15 orders)")
        sweepRun.toolVersion = "GAP 4"
        sweepRun.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + 260)
        sweepRun.startedAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + 250)
        sweepRun.durationSeconds = 9
        sweepRun.outcome = .completed
        sweepRun.verdict = .holds
        sweepRun.runByID = you.stableID
        theorem.evidence = [sweepRun]
        sweepCell.statementID = theorem.stableID
        sweepRun.cell = sweepCell

        // A plain exchange with A after the fan-out: a complete reply, a stopped one and a failed one.
        let (plainQuestion, reply) = exchange(
            state: state, problem: problem, branch: main, you: byYou, slot: slotA, at: 800_000_000 + 600,
            prompt: #"Is the case $p = 2$ special in step 5 of your proof? Explain without changing the proof."#,
            reply: #"It is forced rather than special. Step 4 gives $q \mid p + 1$ and step 2 gives $q > p$, so $q = p + 1$. Of two consecutive integers greater than $1$, one is even, so both are prime only when they are $2$ and $3$. Hence $(p, q) = (2, 3)$ and $|G| = 12$, which step 6 treats separately. Nothing in steps 1 to 4 uses that $p$ is odd."#)
        reply.request?.usageReported = true
        reply.request?.stopReason = StopReason.endTurn.stored
        let usage = TokenUsage(input: 61, cacheWrite: 0, cacheRead: 2_412, output: 1_386)
        reply.request?.inputTokens = usage.input
        reply.request?.cachedInputTokens = usage.cacheRead
        reply.request?.outputTokens = usage.output
        reply.request?.answeredModelID = ModelCatalog.claudeOpus55.id
        reply.request?.estimatedCost = ModelCatalog.cost(usage, .known(ModelCatalog.claudeOpus55))

        let (_, interruptedReply) = exchange(
            state: state, problem: problem, branch: main, you: byYou, slot: slotA, at: 800_000_000 + 720,
            prompt: #"Now outline the same argument for $|G| = p^2 q^2$."#,
            reply: #"Here the counts are $n_p \in \{1, q, q^2\}$ with $n_p \equiv 1 \pmod{p}$, and $n_q \in \{1, p, p^2\}$ with $n_q \equiv 1 \pmod{q}$. Assume $p < q$. Then $n_q = p$ is impossible as before, so"#)
        interruptedReply.interrupted = true
        interruptedReply.request?.stopReason = "stopped"
        interruptedReply.request?.inputTokens = 64
        interruptedReply.request?.cachedInputTokens = 2_540
        interruptedReply.request?.estimatedCost = ModelCatalog.cost(
            TokenUsage(input: 64, cacheRead: 2_540), .known(ModelCatalog.claudeOpus55))

        let (_, failedReply) = exchange(
            state: state, problem: problem, branch: main, you: byYou, slot: slotA, at: 800_000_000 + 840,
            prompt: "Continue the outline from where you stopped.", reply: "")
        let overloaded = ProviderError.overloaded("Overloaded")
        failedReply.request?.errorKind = overloaded.kind
        failedReply.request?.errorMessage = overloaded.message
        failedReply.request?.estimatedCost = 0

        // The side branches. On Class equation, You and A tried the class equation.
        let (_, deadEndReply) = exchange(
            state: state, problem: problem, branch: classEquation, you: byYou, slot: slotA, at: 800_000_000 + 1_000,
            prompt: #"Try the class equation: can $|Z(G)|$ decide which Sylow subgroup is normal?"#,
            reply: #"Writing $|G| = |Z(G)| + \sum [G : C_G(x)]$ bounds the centralizers, not $n_q$. Without more on $Z(G)$ the cases do not close, and each route falls back on the Sylow counts."#)
        // On Induction on |G|, B made an attempt; its step 2 is the one worth salvaging (`makeSalvaged`).
        let inductionPrompt = Message(author: byYou, bodyLaTeX: #"@B try induction on $|G|$: pass to $G/N$ for a normal subgroup $N$."#, kind: .prompt)
        inductionPrompt.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + 1_090)
        let inductionAttempt = attempt(author: byB, at: 1_100, steps: [
            (#"If $G$ has a normal subgroup $N$ with $1 < |N| < |G|$, then $|G/N|$ divides $p^2 q$."#, "Quotient order", .routine),
            (#"If neither Sylow subgroup of $G$ is normal, then $n_p = q \equiv 1 \pmod{p}$, so $q > p$."#, "q > p", .standard),
            (#"But $|G/N|$ need not have the form $p^2 q$, so the induction hypothesis does not apply to $G/N$."#, "Induction stalls", .guess),
        ])
        let inductionMessage = Message(author: byB, kind: .attempt)
        inductionMessage.proofAttempt = inductionAttempt
        inductionMessage.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + 1_100)
        inductionMessage.derivedFromIDs = [inductionPrompt.stableID]
        induction.messages = [inductionPrompt, inductionMessage]
        // A fork from A's attempt, made inside the fan-out: it reads the prompt and A's attempt, never B's.
        let fork = Branch(name: "Parity argument")
        fork.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + 1_190)
        problem.branches = (problem.branches ?? []) + [fork]
        fork.forkedFrom = messageA
        fork.parent = main
        let (_, forkReply) = exchange(
            state: state, problem: problem, branch: fork, you: byYou, slot: slotA, at: 800_000_000 + 1_200,
            prompt: #"Expand step 5: why must the primes be $2$ and $3$?"#,
            reply: #"If $q = p + 1$ and both are prime, one of them is even, hence equal to $2$. Since $q > p \geq 2$, $p = 2$ and $q = 3$."#)

        // Retired, with who wrote each reason and which message it was edited from.
        let retiredAt = day(11, 1)
        for (branch, state, writer) in [(classEquation, BranchState.deadEnd, you), (induction, .deadEnd, you),
                                        (complement, .parked, mk)] {
            branch.state = state
            branch.includeReasonInContext = state == .deadEnd
            branch.stateChangedByID = writer.stableID
            branch.stateChangedAt = retiredAt
            branch.reasonByID = writer.stableID
            branch.reasonAt = retiredAt
            if branch.reasonForModels != nil {
                branch.modelTextByID = writer.stableID
                branch.modelTextAt = retiredAt
            }
        }
        classEquation.reasonFromMessageID = deadEndReply.stableID

        // A was adopted as the main line: its steps are the theorem's proof (set above).
        problem.adoptedAttemptID = attemptA.stableID
        problem.adoptedByID = you.stableID
        problem.adoptedAt = day(11, 20)

        try? context.save()
        return Handles(state: state, problem: problem, you: you, mk: mk, slotA: slotA, slotB: slotB, slotC: slotC,
                       attemptA: attemptA, attemptB: attemptB, theorem: theorem,
                       lemmas: [lemma1, lemma2, lemma3, lemma4], refutedClaim: refuted, conjecture: conjecture,
                       cappedLemma: lemma5, onRefutedClaim: lemma6, belowRefuted: lemma7,
                       mainBranch: main, question: plainQuestion, reply: reply, interruptedReply: interruptedReply,
                       failedReply: failedReply, fanOutPrompt: prompt, fanOut: fanOut, messageA: messageA,
                       messageB: messageB, refereeMessage: refereeMessage, alignment: alignment,
                       classEquation: classEquation, deadEndReply: deadEndReply, induction: induction,
                       inductionAttempt: inductionAttempt, parked: complement, fork: fork, forkReply: forkReply)
    }

    /// The example with what verification adds: a formalizer D and a scout E; D's Lean draft for Lem 6 waiting for
    /// Check; Lem 7 checked with an error; E's Python cell for Claim 2, run by You, its code reporting a
    /// counterexample nobody has accepted; a timed-out run of the GAP sweep; an unchecked citation and one whose
    /// lookup failed. `-SangakuFixtureVerified YES` opens it.
    static func makeVerified(services: Services = .offline) -> Handles {
        let fixture = make(services: services)
        let context = fixture.state.container.mainContext
        let problem = fixture.problem
        let slotD = slot("D", .formalizer, .modelC, "claude-opus-5-5")
        let slotE = slot("E", .scout, .modelB, "claude-sonnet-5-5")
        problem.modelSlots = (problem.modelSlots ?? []) + [slotD, slotE]

        let draft = Message(author: .model(slotD.slotID), bodyLaTeX: "Reads $q \\mid p - 1$ as divisibility in $\\mathbb{N}$; the Sylow count is `Nat.card (Sylow q G)`.",
                            kind: .leanDraft)
        draft.createdAt = day(11, 50)
        context.insert(draft)
        draft.leanDraft = LeanDraft(statementID: fixture.onRefutedClaim.stableID, statementPart: LeanFixtureCode.lemma6.statementPart,
                                    proofPart: LeanFixtureCode.lemma6.proofPart)
        draft.leanDraft?.createdAt = draft.createdAt

        let failed = LeanResult()
        failed.createdAt = day(11, 52)
        context.insert(failed)
        failed.record(.fixture(statementID: fixture.belowRefuted.stableID, source: LeanFixtureCode.lemma7, axioms: ["sorryAx"],
                               messages: [LeanMessage(severity: "error", line: 3, column: 2,
                                                      text: "unknown identifier 'Sylow.card_eq_p'", kind: "[anonymous]")]),
                      module: TextDigest(of: "fixture"), environment: LeanFixtureCode.environment,
                      checkedBy: fixture.you.stableID, sourceAuthor: .human(fixture.you.personID), draftMessageID: nil,
                      duration: 38, at: day(11, 52))
        fixture.belowRefuted.leanResult = failed

        let claim = Statement(kind: .claim, label: "Claim 2",
                              statementLaTeX: "In every group of order $p^2 q$, the Sylow $q$-subgroup is normal.",
                              author: .model(fixture.slotB.slotID))
        claim.createdAt = day(11, 54)
        context.insert(claim)
        problem.statements = (problem.statements ?? []) + [claim]
        let scout = Message(author: .model(slotE.slotID), bodyLaTeX: "Counts the Sylow $3$-subgroups of $A_4$, the smallest case with $p = 2$, $q = 3$.",
                            kind: .compute)
        scout.createdAt = day(11, 56)
        context.insert(scout)
        let cell = ComputeCell(tool: .python, code: alternatingGroupCode, scope: "the alternating group $A_4$ (order 12)",
                               claim: "The Sylow 3-subgroup of a group of order 12 is normal.", statementID: claim.stableID)
        cell.createdAt = scout.createdAt
        scout.computeCell = cell
        let run = Evidence(tool: .python, code: alternatingGroupCode,
                           output: "Sylow 3-subgroups of A4: 4\nsangaku-result: counterexample A4 has 4 Sylow 3-subgroups\n",
                           passed: false, scope: cell.scope)
        run.createdAt = day(11, 58)
        run.startedAt = day(11, 57)
        run.durationSeconds = 0.4
        run.outcome = .completed
        run.verdict = .counterexample
        run.runByID = fixture.you.stableID
        run.toolVersion = "Python 3.15.0"
        context.insert(run)
        run.cell = cell
        claim.evidence = [run]

        let timedOut = Evidence(tool: .gap, code: gapSweepCode, output: "", passed: false,
                                scope: "every group of each order p²q ≤ 200")
        timedOut.createdAt = day(12, 5)
        timedOut.startedAt = day(12, 3)
        timedOut.durationSeconds = 120
        timedOut.outcome = .timedOut
        timedOut.runByID = fixture.you.stableID
        context.insert(timedOut)
        fixture.theorem.evidence = (fixture.theorem.evidence ?? []) + [timedOut]
        fixture.mainBranch.messages = (fixture.mainBranch.messages ?? []) + [draft, scout]

        let steps = fixture.attemptA.sortedSteps
        let unchecked = Citation(rawText: "Sylow, Théorèmes sur les groupes de substitutions, Math. Ann. 5 (1872)",
                                 status: .unverified, author: .model(fixture.slotA.slotID))
        unchecked.createdAt = day(11, 0)
        let undecided = Citation(rawText: "Burnside, Theory of Groups of Finite Order, 2nd ed. (1911), §243",
                                 status: .unverified, author: .human(fixture.you.personID))
        undecided.createdAt = day(11, 1)
        undecided.checkedAt = day(11, 2)
        undecided.lookupDetail = "arXiv: timed out; zbMATH Open: offline"
        steps[2].citations = (steps[2].citations ?? []) + [unchecked]
        steps[3].citations = (steps[3].citations ?? []) + [undecided]
        try? context.save()
        return fixture
    }

    /// Python that counts the Sylow 3-subgroups of $A_4$, self-contained.
    static let alternatingGroupCode = """
    from itertools import permutations

    def compose(a, b):
        return tuple(a[b[i]] for i in range(4))

    def is_even(p):
        inversions = sum(1 for i in range(4) for j in range(i + 1, 4) if p[i] > p[j])
        return inversions % 2 == 0

    identity = (0, 1, 2, 3)
    a4 = [p for p in permutations(range(4)) if is_even(p)]
    order_three = [p for p in a4 if p != identity and compose(p, compose(p, p)) == identity]
    subgroups = {frozenset([identity, p, compose(p, p)]) for p in order_three}
    print(f"Sylow 3-subgroups of A4: {len(subgroups)}")
    if len(subgroups) > 1:
        print(f"sangaku-result: counterexample A4 has {len(subgroups)} Sylow 3-subgroups")
    else:
        print("sangaku-result: holds")
    """

    /// The example with a lemma salvaged from a dead end: step 2 of B's attempt on Induction on |G| ("q > p"),
    /// promoted by You as Lem 8.
    static func makeSalvaged() -> Handles {
        let fixture = make()
        let attempt = fixture.inductionAttempt
        let texts = Dictionary(uniqueKeysWithValues: attempt.sortedSteps.map { ($0.index, $0.textLaTeX) })
        var draft = PromotionDraft(attemptID: attempt.stableID, first: 2, last: 2,
                                   existingLabels: (fixture.problem.statements ?? []).map(\.label), texts: texts)
        draft.editText(#"If neither Sylow subgroup is normal, then $q > p$."#)
        _ = try? fixture.state.graph.promote(draft, in: fixture.problem)
        return fixture
    }

    /// A question from You and A's reply, with the request record `ContextBuilder` gives for it.
    private static func exchange(state: AppState, problem: Problem, branch: Branch, you: Author, slot: ModelSlot,
                                 at time: TimeInterval, prompt: String, reply text: String) -> (Message, Message) {
        let question = Message(author: you, bodyLaTeX: prompt, kind: .prompt)
        question.createdAt = Date(timeIntervalSinceReferenceDate: time)
        let reply = Message(author: .model(slot.slotID), bodyLaTeX: text, kind: .reply)
        reply.createdAt = question.createdAt.addingTimeInterval(30)
        reply.derivedFromIDs = [question.stableID]

        let record = RequestRecord()
        record.createdAt = question.createdAt
        record.providerID = slot.providerID
        record.modelID = slot.modelID
        record.parametersJSON = JSONColumn.encode(RequestParameters(
            model: slot.modelID, maxOutputTokens: ThreadManager.maxOutputTokens, effort: .standard, stream: true,
            apiVersion: AnthropicWire.apiVersion, thinking: AnthropicWire.thinkingDescription))
        let people = (try? state.container.mainContext.fetch(FetchDescriptor<Person>())) ?? []
        let snapshot = ProblemSnapshot.make(problem: problem, branch: branch, notation: state.problems.notation(for: problem),
                                            people: people, liveMessageIDs: [])
        if let prompt = PromptLibrary.bundled.prompt(for: .prover),
           let built = try? ContextBuilder().build(ContextInput(
               snapshot: snapshot, providerID: slot.providerID, purpose: .reply(slot: slot.slotID, fanOut: nil),
               rolePrompt: prompt, pending: question.bodyLaTeX, inputBudget: nil)) {
            record.promptVersion = built.promptVersion
            record.contextText = built.transcript
            record.estimatedInputTokens = built.totalTokens
        }
        record.finishedAt = reply.createdAt
        reply.request = record
        branch.messages = (branch.messages ?? []) + [question, reply]
        return (question, reply)
    }

    /// A finished attempt's or referee's record, with the context `ContextBuilder` gives for it while `live` are
    /// still running, and its output as the model wrote it.
    private static func structuredRecord(state: AppState, problem: Problem, branch: Branch, slot: ModelSlot,
                                         purpose: RequestPurpose, live: Set<UUID>, at time: Date, finished: Date,
                                         output: String, usage: TokenUsage) -> RequestRecord {
        let referee = if case .referee = purpose { true } else { false }
        let format: OutputFormat = referee ? .refereeVerdicts(letters: ["A", "B"]) : .attempt
        let record = RequestRecord()
        record.createdAt = time
        record.providerID = slot.providerID
        record.modelID = slot.modelID
        record.parametersJSON = JSONColumn.encode(RequestParameters(
            model: slot.modelID, maxOutputTokens: ThreadManager.maxOutputTokens, effort: .standard, stream: true,
            apiVersion: AnthropicWire.apiVersion, thinking: AnthropicWire.thinkingDescription, outputFormat: format.tag))
        let people = (try? state.container.mainContext.fetch(FetchDescriptor<Person>())) ?? []
        let snapshot = ProblemSnapshot.make(problem: problem, branch: branch, notation: state.problems.notation(for: problem),
                                            people: people, liveMessageIDs: live)
        if let prompt = PromptLibrary.bundled.prompt(for: referee ? .referee : .prover, structured: true),
           let built = try? ContextBuilder().build(ContextInput(
               snapshot: snapshot, providerID: slot.providerID, purpose: purpose, rolePrompt: prompt,
               pending: referee ? RequestPreparer.refereeInstruction(letters: ["A", "B"]) : nil, inputBudget: nil,
               format: format)) {
            record.promptVersion = built.promptVersion
            record.contextText = built.transcript
            record.estimatedInputTokens = built.totalTokens
        }
        record.rawOutput = output
        record.parseState = .clean
        record.usageReported = true
        record.stopReason = StopReason.endTurn.stored
        record.inputTokens = usage.input
        record.outputTokens = usage.output
        record.answeredModelID = slot.modelID
        record.estimatedCost = ModelCatalog.cost(usage, .known(ModelCatalog.claudeOpus55))
        record.finishedAt = finished
        return record
    }

    /// Self-contained: the helpers are defined in the cell itself (spec: Evidence code).
    static let gapSweepCode = """
    IsP2QOrder := function(n)
      local f;
      f := Collected(FactorsInt(n));
      return Length(f) = 2 and SortedList(List(f, x -> x[2])) = [1, 2];
    end;
    HasNormalSylow := G -> ForAny(Set(FactorsInt(Size(G))), p -> IsNormal(G, SylowSubgroup(G, p)));
    orders := Filtered([1..100], IsP2QOrder);
    ForAll(orders, n -> ForAll(AllSmallGroups(n), HasNormalSylow));
    """

    private static func slot(_ letter: String, _ role: SlotRole, _ color: ColorToken, _ model: String) -> ModelSlot {
        let slot = ModelSlot(letter: letter, providerID: "anthropic", modelID: model, role: role)
        slot.colorTokenRaw = color.rawValue
        return slot
    }

    /// An attempt whose steps were first written `seconds` after the fan-out's prompt.
    private static func attempt(author: Author, at seconds: TimeInterval, steps: [(String, String, Confidence)]) -> ProofAttempt {
        let attempt = ProofAttempt(parsedCleanly: true)
        let time = Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
        attempt.steps = steps.enumerated().map { offset, step in
            let (text, establishes, confidence) = step
            let s = Step(index: offset + 1, textLaTeX: text, establishes: establishes, confidence: confidence)
            s.createdAt = time
            let first = StepRevision(author: author, textLaTeX: text, establishes: establishes)
            first.createdAt = time
            s.revisions = [first]
            return s
        }
        return attempt
    }

    /// The model's alignment of A and B: steps 1–4 equivalent, step 5 diverging where B claims q ∤ p + 1, step 6 only in A.
    private static func alignment(_ attemptA: ProofAttempt, _ attemptB: ProofAttempt, by referee: ModelSlot,
                                  at time: Date) -> Alignment {
        let aIsFirst = SideOrder.orient(attemptA.stableID, attemptB.stableID).first == attemptA.stableID
        let alignment = aIsFirst ? Alignment(attemptAID: attemptA.stableID, attemptBID: attemptB.stableID)
                                 : Alignment(attemptAID: attemptB.stableID, attemptBID: attemptA.stableID)
        alignment.createdAt = time
        let stepsA = attemptA.sortedSteps, stepsB = attemptB.sortedSteps
        let bSide = aIsFirst ? 2 : 1
        func row(_ fromA: Step?, _ fromB: Step?, _ verdict: AlignmentVerdict, label: String, note: String? = nil,
                 phrases: (String?, String?) = (nil, nil)) -> AlignmentRow {
            let (first, second) = aIsFirst ? (fromA, fromB) : (fromB, fromA)
            let (firstPhrase, secondPhrase) = aIsFirst ? phrases : (phrases.1, phrases.0)
            let oriented: AlignmentVerdict = switch verdict {
            case .onlyA: aIsFirst ? .onlyA : .onlyB
            case .onlyB: aIsFirst ? .onlyB : .onlyA
            default: verdict
            }
            return AlignmentRow(stepAID: first?.stableID, stepBID: second?.stableID, label: label,
                                verdict: oriented.rawValue, note: note, keyPhraseA: firstPhrase, keyPhraseB: secondPhrase,
                                revisionAID: first?.latestRevision?.stableID, revisionBID: second?.latestRevision?.stableID)
        }
        alignment.rows = (0..<4).map { row(stepsA[$0], stepsB[$0], .equivalent, label: stepsA[$0].establishes) } + [
            row(stepsA[4], stepsB[4], .diverge, label: "Resolve q | p + 1",
                note: #"Attempt \#(bSide)'s step is false: $q = p + 1$ happens for $(p, q) = (2, 3)$."#,
                phrases: (#"we get $q = p + 1$"#, #"$q$ cannot divide $p + 1$"#)),
            row(stepsA[5], nil, .onlyA, label: "Order 12 case",
                note: "Needed only because of the row above."),
        ]
        alignment.alignerSlotID = referee.stableID
        alignment.modelSummary = "The attempts agree up to step 4 and part ways at step 5."
        return alignment
    }

    /// A new revision of `step` with new text and the same `establishes`, mirrored onto the step.
    @discardableResult
    private static func revise(_ step: Step, by author: Author, at time: Date, text: String) -> StepRevision {
        let revision = StepRevision(author: author, textLaTeX: text, establishes: step.establishes)
        revision.createdAt = time
        step.revisions = (step.revisions ?? []) + [revision]
        step.textLaTeX = text
        return revision
    }

    /// A time on 2026-05-09 (UTC), the morning after the fan-out. Times show in the viewer's time zone.
    static func day(_ hour: Int, _ minute: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: 799_977_600 + Double(hour * 3600 + minute * 60))
    }

    /// A person's confirmation that a statement's checked Lean statement says what its wording says.
    private static func fidelity(_ statement: Statement, by person: Person, at date: Date) -> FidelityReview {
        let review = FidelityReview(reviewer: person.personID,
                                    leanStatementSource: statement.leanResult?.leanStatementSource ?? "",
                                    verdict: .matches)
        review.informalWording = statement.statementLaTeX
        review.createdAt = date
        return review
    }
}

/// Injects the fixture into a preview: `#Preview(traits: .fixture)`.
struct FixturePreview: PreviewModifier {
    static func makeSharedContext() async throws -> PreviewFixtures.Handles {
        PreviewFixtures.make()
    }

    func body(content: Content, context: PreviewFixtures.Handles) -> some View {
        content.fixtureEnvironment(context)
    }
}

/// The same with a lemma salvaged from a dead end (`PreviewFixtures.makeSalvaged`).
struct SalvagedFixturePreview: PreviewModifier {
    static func makeSharedContext() async throws -> PreviewFixtures.Handles {
        PreviewFixtures.makeSalvaged()
    }

    func body(content: Content, context: PreviewFixtures.Handles) -> some View {
        content.fixtureEnvironment(context)
    }
}

/// The same with what verification adds (`PreviewFixtures.makeVerified`).
struct VerifiedFixturePreview: PreviewModifier {
    static func makeSharedContext() async throws -> PreviewFixtures.Handles {
        PreviewFixtures.makeVerified()
    }

    func body(content: Content, context: PreviewFixtures.Handles) -> some View {
        content.fixtureEnvironment(context)
    }
}

private extension View {
    func fixtureEnvironment(_ fixture: PreviewFixtures.Handles) -> some View {
        appEnvironment(fixture.state)
            .environment(\.mathContext, fixture.mathContext)
            .modelContainer(fixture.state.container)
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    static var fixture: Self { .modifier(FixturePreview()) }
    static var salvagedFixture: Self { .modifier(SalvagedFixturePreview()) }
    static var verifiedFixture: Self { .modifier(VerifiedFixturePreview()) }
}
#endif
