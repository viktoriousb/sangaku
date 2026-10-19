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

        /// From the launch arguments; nil when no fixture is asked for.
        static func from(arguments: [String]) -> Services? {
            if arguments.contains("-SangakuFixtureLive") { return .live }
            guard arguments.contains("-SangakuFixture") else { return nil }
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

        // Branches
        let main = problem.sortedBranches[0]
        main.name = "Counting elements"
        let classEquation = Branch(name: "Class equation", state: .deadEnd)
        classEquation.reason = #"The class equation constrains centralizer sizes, not $n_q$. Without control of $Z(G)$ the case split never closed, and every route fell back on the Sylow counts anyway."#
        classEquation.reasonForModels = "Tried: class equation alone. Stalls on |Z(G)|. Don't retry without new input on the center."
        classEquation.includeReasonInContext = true
        let induction = Branch(name: "Induction on |G|", state: .deadEnd)
        induction.reason = "Passing to a quotient loses the order p²q shape, so the induction hypothesis never applies."
        induction.reasonForModels = "Tried: induction on |G|. Quotients leave the p²q family."
        induction.includeReasonInContext = true
        let complement = Branch(name: "Normal p-complement", state: .parked)
        complement.reason = "Burnside's transfer theorem gives a normal p-complement when a Sylow p-subgroup is central in its normalizer. That hypothesis doesn't hold in general here. MK: revisit for p²q²."
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

        let sweep = Message(author: byA, bodyLaTeX: gapSweepCode, kind: .compute)
        sweep.derivedFromIDs = [messageA.stableID]
        sweep.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + 240)
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
        refuted.refutationAcceptedAt = Date.now
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

        let standard = ["propext", "Classical.choice", "Quot.sound"]
        lemma1.leanResult = lean("theorem sylow_counts (hG : Nat.card G = p ^ 2 * q) : …", axioms: standard)
        lemma1.fidelityReviews = [FidelityReview(reviewer: you.personID, leanStatementSource: lemma1.leanResult!.leanStatementSource, verdict: .matches)]
        lemma2.leanResult = lean("theorem q_gt_p (h : ¬ ∃ r, (Sylow r G).Normal) : q > p", axioms: standard)
        lemma3.leanResult = lean("theorem p_q_eq (hp : n_p = q) (hq : n_q = p ^ 2) : (p, q) = (2, 3)", axioms: standard)
        let lemma4Lean = lean("lemma order_twelve (hG : Nat.card G = 12) : ∃ p (P : Sylow p G), (P : Subgroup G).Normal",
                              axioms: standard + ["sorryAx"], sorry: 1)
        lemma4Lean.messages = [LeanMessage(severity: "warning", line: 4, column: 2, text: "declaration uses 'sorry'")]
        lemma4.leanResult = lemma4Lean
        lemma5.leanResult = lean("theorem case_excluded (hp : n_p = q) (hq : n_q = p ^ 2) : False", axioms: standard)
        lemma5.fidelityReviews = [FidelityReview(reviewer: mk.personID, leanStatementSource: lemma5.leanResult!.leanStatementSource, verdict: .matches)]

        theorem.evidence = [Evidence(tool: .gap, code: gapSweepCode, output: "true", passed: true,
                                     scope: "every group of each order p²q ≤ 100 (15 orders)")]
        theorem.evidence?.first?.toolVersion = "GAP 4"

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

        try? context.save()
        return Handles(state: state, problem: problem, you: you, mk: mk, slotA: slotA, slotB: slotB, slotC: slotC,
                       attemptA: attemptA, attemptB: attemptB, theorem: theorem,
                       lemmas: [lemma1, lemma2, lemma3, lemma4], refutedClaim: refuted, conjecture: conjecture,
                       cappedLemma: lemma5, onRefutedClaim: lemma6, belowRefuted: lemma7,
                       mainBranch: main, question: plainQuestion, reply: reply, interruptedReply: interruptedReply,
                       failedReply: failedReply, fanOutPrompt: prompt, fanOut: fanOut, messageA: messageA,
                       messageB: messageB, refereeMessage: refereeMessage)
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

    private static func lean(_ statement: String, axioms: [String], sorry: Int = 0) -> LeanResult {
        let result = LeanResult(source: statement + " := by\n  …", leanStatementSource: statement, sorryCount: sorry, axioms: axioms)
        result.checkedAt = Date.now
        return result
    }
}

/// Injects the fixture into a preview: `#Preview(traits: .fixture)`.
struct FixturePreview: PreviewModifier {
    static func makeSharedContext() async throws -> PreviewFixtures.Handles {
        PreviewFixtures.make()
    }

    func body(content: Content, context: PreviewFixtures.Handles) -> some View {
        content
            .environment(\.mathRenderer, context.state.renderer)
            .environment(\.problemManager, context.state.problems)
            .environment(\.saveScheduler, context.state.saves)
            .environment(\.threadManager, context.state.threads)
            .environment(\.statementGraph, context.state.graph)
            .environment(\.reviewManager, context.state.reviews)
            .environment(\.credentialManager, context.state.credentials)
            .environment(\.mathContext, context.mathContext)
            .modelContainer(context.state.container)
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    static var fixture: Self { .modifier(FixturePreview()) }
}
#endif
