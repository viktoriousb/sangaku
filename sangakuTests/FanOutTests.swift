import Foundation
import SwiftData
import Testing
@testable import sangaku

@Suite("Fan-out run")
struct FanOutRunTests {
    private let a = UUID(), b = UUID(), c = UUID(), referee = UUID()

    private func begin(sequential: Bool, referee: UUID?) -> (FanOutRun, [FanOutRun.Command]) {
        FanOutRun.begin(fanOutID: UUID(), problemID: UUID(), branchID: UUID(), members: [a, b, c], sequential: sequential,
                        refereeSlotID: referee, effort: .high)
    }

    @Test("Independent: every prover starts at once; invariant 4: the referee only after every attempt has ended")
    func parallel() {
        var (run, commands) = begin(sequential: false, referee: referee)
        #expect(commands == [.startMember(a), .startMember(b), .startMember(c)])
        #expect(run.handle(.memberEnded(a)).isEmpty)
        #expect(run.handle(.memberEnded(c)).isEmpty)
        #expect(!run.isSettled)
        #expect(run.handle(.memberEnded(b)) == [.startReferee(slotID: referee)])
        #expect(run.handle(.refereeEnded).isEmpty)
        #expect(run.isSettled)
    }

    @Test("Shared: one prover at a time, in order, then the referee")
    func sequential() {
        var (run, commands) = begin(sequential: true, referee: referee)
        #expect(commands == [.startMember(a)])
        #expect(run.handle(.memberEnded(a)) == [.startMember(b)])
        #expect(run.handle(.memberEnded(b)) == [.startMember(c)])
        #expect(run.handle(.memberEnded(c)) == [.startReferee(slotID: referee)])
    }

    @Test("Stopping a waiting prover takes it out of the queue; the running one is not disturbed and the referee still follows")
    func stopQueued() {
        var (run, _) = begin(sequential: true, referee: referee)
        #expect(run.handle(.memberEnded(b)).isEmpty, "A is still running")
        #expect(run.handle(.memberEnded(a)) == [.startMember(c)])
        #expect(run.handle(.memberEnded(c)) == [.startReferee(slotID: referee)])
    }

    @Test("Stop all cancels a waiting referee and starts nothing more; so does quitting")
    func stopAll() {
        for event in [FanOutRun.Event.stopAll, .shutdown] {
            var (run, _) = begin(sequential: true, referee: referee)
            #expect(run.handle(event).isEmpty)
            #expect(run.referee == .cancelled)
            for member in [a, b, c] { #expect(run.handle(.memberEnded(member)).isEmpty) }
            #expect(run.isSettled)
        }
    }

    @Test("A referee asked for by hand starts only once every attempt has ended, and may run again")
    func manualReferee() {
        var (run, _) = begin(sequential: false, referee: nil)
        #expect(run.handle(.refereeRequested(slotID: referee)).isEmpty, "attempts still running")
        _ = run.handle(.memberEnded(a))
        _ = run.handle(.memberEnded(b))
        #expect(run.handle(.memberEnded(c)).isEmpty, "no referee was chosen")
        #expect(run.isSettled)
        #expect(run.handle(.refereeRequested(slotID: referee)) == [.startReferee(slotID: referee)])
        #expect(run.handle(.refereeRequested(slotID: referee)).isEmpty, "not while it runs")
        _ = run.handle(.refereeEnded)
        #expect(run.handle(.refereeRequested(slotID: referee)) == [.startReferee(slotID: referee)])
    }
}

@Suite("Recipients and the plan")
struct SelectionTests {
    private func slot(_ letter: String, _ role: SlotRole) -> ProblemSnapshot.SlotDigest {
        ProblemSnapshot.SlotDigest(id: ModelSlotID(UUID()), letter: letter, providerID: ProviderID.anthropic,
                                   modelID: "claude-opus-5-5", role: role)
    }

    @Test("No choice means the first prover; only provers receive; a referee must be a referee; letter order")
    func resolves() {
        let a = slot("A", .prover), b = slot("B", .prover), c = slot("C", .referee), d = slot("D", .scout)
        let slots = [c, b, d, a]
        #expect(SendSelection().resolved(slots).provers == [a])
        #expect(!SendSelection().resolved(slots).isFanOut)
        let all = SendSelection(recipients: [b.id.rawValue, a.id.rawValue, c.id.rawValue, d.id.rawValue],
                                refereeSlotID: c.id.rawValue)
        #expect(all.resolved(slots).provers == [a, b])
        #expect(all.resolved(slots).referee == c)
        #expect(all.resolved(slots).isFanOut)
        #expect(SendSelection(refereeSlotID: b.id.rawValue).resolved(slots).referee == nil, "B is a prover")
        #expect(SendSelection(refereeSlotID: c.id.rawValue).resolved(slots).isFanOut, "one prover and a referee")
        #expect(SendSelection(recipients: [UUID()]).resolved(slots).provers == [a], "a slot that is gone drops out")
    }

    @Test("Totals: input costs add up, an unknown price stays unknown, the output ceiling includes the referee")
    func totals() {
        let known = ModelResolution.known(ModelCatalog.claudeOpus55)
        var plan = SendPlan(providerID: ProviderID.anthropic, providerName: "Anthropic")
        plan.recipients = [
            SendPlan.Recipient(letter: "A", model: known, cost: .range(low: 0.01, high: 0.02), outputCeiling: 1.28),
            SendPlan.Recipient(letter: "B", model: known, cost: .range(low: 0.01, high: 0.03), outputCeiling: 1.28),
        ]
        plan.referee = SendPlan.Referee(letter: "C", model: known, outputCeiling: 1.28)
        #expect(plan.inputCost == .range(low: 0.02, high: 0.05))
        #expect(abs((plan.outputCeiling ?? 0) - 3.84) < 1e-9)
        #expect(plan.sendLabel == "Send to A, B, then C")
        plan.recipients[1].cost = .unknown(modelID: "x")
        #expect(plan.inputCost == .unknown(modelID: "x"))
        plan.referee?.outputCeiling = nil
        #expect(plan.outputCeiling == nil)
    }

    @Test("Toggling recipients: one can be added or taken away, but the last prover always stays")
    func toggling() {
        let a = UUID(), b = UUID()
        let selection = SendSelection(refereeSlotID: UUID())
        #expect(selection.toggling(b, on: true, chosen: [a]).recipients == [a, b])
        #expect(selection.toggling(a, on: false, chosen: [a, b]).recipients == [b])
        #expect(selection.toggling(a, on: false, chosen: [a]).recipients == [a])
        #expect(selection.toggling(b, on: true, chosen: [a]).refereeSlotID == selection.refereeSlotID)
    }

    @Test("A referee that gave no verdicts is not reported as having refereed")
    func headerWithoutVerdicts() {
        let header = FanOutHeader(visibility: .independent, attempts: [.init(letter: "A", state: .finished)],
                                  refereeLetter: "C", referee: .noVerdicts)
        #expect(header.refereeLine == "C gave no verdicts that could be read")
        #expect(header.title == "1 independent attempt · finished")
    }

    @Test("Header words: progress, who saw whom, and the referee")
    func header() {
        let both = FanOutHeader(visibility: .independent,
                                attempts: [.init(letter: "A", state: .finished), .init(letter: "B", state: .finished)],
                                refereeLetter: "C", referee: .waiting)
        #expect(both.title == "2 independent attempts · both finished")
        #expect(both.visibilityLine == "Independent: A and B can't see each other")
        #expect(both.refereeLine == "C waits for both, then sees both")
        let mixed = FanOutHeader(visibility: .shared,
                                 attempts: [.init(letter: "A", state: .stopped), .init(letter: "B", state: .running),
                                            .init(letter: "C", state: .queued)],
                                 refereeLetter: "D", referee: .notRun)
        #expect(mixed.title == "3 shared attempts · 1 running, 1 waiting, A stopped")
        #expect(mixed.visibilityLine == "Shared: each sees the attempts before it (A, then B, then C)")
        #expect(mixed.refereeLine == "D has not refereed")
    }
}

@Suite("Fan-out", .serialized)
struct FanOutManagerTests {
    private let container: ModelContainer
    private let saves: SaveScheduler
    private let problems: ProblemManager
    private let credentials: CredentialManager
    private let provider = ScriptedProvider()
    private let threads: ThreadManager
    private let problem: Problem
    private let branch: Branch
    private let a: ModelSlot, b: ModelSlot, c: ModelSlot

    init() throws {
        container = try ModelContainerFactory.make(.inMemory)
        saves = SaveScheduler(context: container.mainContext, delay: .seconds(60))
        problems = ProblemManager(context: container.mainContext, saves: saves)
        credentials = CredentialManager(store: InMemorySecretStore())
        threads = ThreadManager(context: container.mainContext, saves: saves, problems: problems,
                                credentials: credentials, registry: ProviderRegistry([provider]))
        problems.willDelete = { [threads] problemID in threads.cancelAll(problemID: problemID) }
        problem = problems.createProblem(title: "Groups of order pq", statementLaTeX: "Let $|G| = pq$ with $p < q$.")
        problems.setProvider(ProviderID.anthropic, allowed: true, for: problem)
        branch = problem.sortedBranches[0]
        a = problems.addSlot(to: problem, providerID: ProviderID.anthropic, modelID: "claude-opus-5-5")
        b = problems.addSlot(to: problem, providerID: ProviderID.anthropic, modelID: "claude-opus-5-5")
        c = problems.addSlot(to: problem, providerID: ProviderID.anthropic, modelID: "claude-opus-5-5", role: .referee)
    }

    private var context: ModelContext { container.mainContext }

    @discardableResult
    private func sendFanOut(_ text: String = "Prove that $G$ is cyclic.", provers: [ModelSlot]? = nil,
                            visibility: FanOutVisibility = .independent, referee: Bool = true) throws -> [Message] {
        let draft = threads.draft(for: branch.stableID)
        draft.text = text
        draft.selection = SendSelection(recipients: Set((provers ?? [a, b]).map(\.stableID)), visibility: visibility,
                                        refereeSlotID: referee ? c.stableID : nil)
        try threads.send(problem: problem, branch: branch, draft: draft)
        return branch.sortedMessages.filter { $0.kind == .attempt }
    }

    private static let attemptA = DemoOutput.attempt(overview: "Count.", steps: [
        ("Sylow counts", .standard, #"$n_q \equiv 1 \pmod{q}$ and $n_q \mid p$."#),
        ("n_q = 1", .routine, "Since $p < q$, $n_q = 1$."),
    ])
    private static let attemptB = DemoOutput.attempt(overview: "", steps: [
        ("Cauchy", .routine, "There are elements of order $p$ and $q$."),
        ("Cyclic", .guess, "Their product has order $pq$."),
    ])

    private func refereeReport(_ letters: [(String, RefereeOutcome, [Int])]) -> String {
        DemoOutput.referee(summary: "Judged.", verdicts: letters.map { ($0.0, $0.1, $0.2, "Reason for \($0.0).") })
    }

    @Test("Independent: one store change, one structured request per prover, built before anything was written")
    func independentSend() throws {
        let attempts = try sendFanOut()
        let prompt = try #require(branch.sortedMessages.first)
        let fanOut = try #require(prompt.fanOut)
        #expect(fanOut.visibility == .independent)
        #expect(fanOut.refereeSlotID == c.stableID)
        #expect(attempts.count == 2)
        #expect(attempts.map(\.author) == [.model(a.slotID), .model(b.slotID)])
        #expect(Set((fanOut.attempts ?? []).compactMap(\.message?.stableID)) == Set(attempts.map(\.stableID)))
        for attempt in attempts {
            #expect(attempt.derivedFromIDs == [prompt.stableID])
            #expect(attempt.request?.promptVersion == "prover-attempt@4")
            #expect(attempt.request?.contextText.hasSuffix("Prove that $G$ is cyclic.") == true)
            #expect(JSONColumn.decode(RequestParameters.self, from: attempt.request?.parametersJSON)?.outputFormat == "proof-attempt@2")
        }
        #expect(provider.requests.count == 2)
        #expect(provider.requests.allSatisfy { $0.format == .attempt })
        #expect(threads.runs[fanOut.stableID]?.refereePending == true)
        #expect(threads.streamingBranchIDs == [branch.stableID])
        #expect(threads.draft(for: branch.stableID).text.isEmpty)
        #expect(threads.draft(for: branch.stableID).selection.refereeSlotID == c.stableID, "the choices stay")
    }

    @Test("A send any recipient would refuse writes nothing and sends nothing")
    func refusedRecipientWritesNothing() throws {
        let tiny = ModelInfo(id: "tiny", providerID: ProviderID.anthropic, displayName: "Tiny",
                             contextWindow: ThreadManager.maxOutputTokens + 100, maxOutputTokens: ThreadManager.maxOutputTokens,
                             minimumCacheablePrefix: 512, pricing: ModelCatalog.claudeOpus55.pricing)
        let small = ThreadManager(context: context, saves: saves, problems: problems, credentials: credentials,
                                  registry: ProviderRegistry([provider]),
                                  catalog: ModelCatalog(models: [ModelCatalog.claudeOpus55, tiny]))
        problems.setModel("tiny", for: b)
        let draft = small.draft(for: branch.stableID)
        draft.text = "Prove it."
        draft.selection = SendSelection(recipients: [a.stableID, b.stableID])
        do {
            try small.send(problem: problem, branch: branch, draft: draft)
            Issue.record("B's window is too small")
        } catch {
            guard case .recipient(letter: "B", .essentialsDoNotFit) = error else { throw error }
        }
        #expect(branch.messages?.isEmpty ?? true)
        #expect(try context.fetchCount(FetchDescriptor<FanOut>()) == 0)
        #expect(provider.requests.isEmpty)
        #expect(draft.text == "Prove it.")

        let noReferee = ThreadManager(context: context, saves: saves, problems: problems, credentials: credentials,
                                      registry: ProviderRegistry([provider]),
                                      prompts: PromptLibrary { name in name == "referee" ? nil : "version: 2\n---\nProve." })
        let other = noReferee.draft(for: branch.stableID)
        other.text = "Prove it."
        other.selection = SendSelection(recipients: [a.stableID], refereeSlotID: c.stableID)
        #expect(throws: SendBlocker.noRolePrompt(.referee)) { try noReferee.send(problem: problem, branch: branch, draft: other) }
        #expect(branch.messages?.isEmpty ?? true)
    }

    @Test("An attempt's steps are written when it ends, each with a first revision by its model (invariant 7)")
    func attemptSteps() async throws {
        let attempts = try sendFanOut(referee: false)
        provider.reply(to: 0, Self.attemptA)
        try await waitUntil { threads.live[attempts[0].stableID] == nil }
        let attempt = try #require(attempts[0].proofAttempt)
        #expect(attempt.parsedCleanly)
        #expect(attempts[0].request?.parseState == .clean)
        #expect(attempts[0].request?.rawOutput == Self.attemptA, "the raw output is kept")
        #expect(attempts[0].bodyLaTeX == "Count.")
        let steps = attempt.sortedSteps
        #expect(steps.map(\.index) == [1, 2])
        #expect(steps.map(\.confidence) == [.standard, .routine])
        #expect(steps[0].textLaTeX == #"$n_q \equiv 1 \pmod{q}$ and $n_q \mid p$."#)
        #expect(steps.allSatisfy { $0.revisions?.count == 1 && $0.latestRevision?.author == .model(a.slotID) })
        #expect(threads.streamingBranchIDs == [branch.stableID], "B still runs")
    }

    @Test("Invariant 4 end to end: the referee waits for every attempt, then sees them all, and its verdicts are stored")
    func refereeAfterAll() async throws {
        let attempts = try sendFanOut()
        provider.reply(to: 0, Self.attemptA)
        try await waitUntil { threads.live[attempts[0].stableID] == nil }
        try await Task.sleep(for: .milliseconds(20))
        #expect(provider.requests.count == 2, "the referee waits for B")
        provider.reply(to: 1, Self.attemptB)
        try await waitUntil { provider.requests.count == 3 }
        let request = try #require(provider.requests.last)
        #expect(request.format == .refereeVerdicts(letters: ["A", "B"]))
        let text = request.turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(text.contains("[Attempt by Model A, to judge]") && text.contains("[Attempt by Model B, to judge]"))
        #expect(text.contains("Step 2 (establishes: n_q = 1; confidence: routine)"))
        #expect(text.contains("Step 2 (establishes: Cyclic; confidence: guess)"),
                "B, which ended last, reaches the referee read as steps: the referee waited for B's output to be read")
        #expect(!text.contains(#""steps":["#), "never as raw output")
        #expect(request.turns.last?.role == .user)
        let referee = try #require(branch.sortedMessages.last)
        #expect(referee.kind == .referee)
        #expect(referee.author == .model(c.slotID))
        #expect(referee.derivedFromIDs == [branch.sortedMessages[0].stableID] + attempts.map(\.stableID))
        #expect(referee.request?.promptVersion == "referee@2")

        provider.reply(to: 2, refereeReport([("A", .complete, []), ("B", .gap, [2])]))
        try await waitUntil { threads.live.isEmpty }
        let verdicts = (branch.sortedMessages[0].fanOut?.verdicts ?? []).sorted { ($0.attempt?.message?.createdAt ?? .distantPast) < ($1.attempt?.message?.createdAt ?? .distantPast) }
        #expect(verdicts.map(\.outcome) == [.complete, .gap])
        #expect(verdicts.allSatisfy { $0.messageID == referee.stableID && $0.refereeSlotID == c.stableID && !$0.sawPartialAttempt })
        #expect(verdicts.allSatisfy { $0.requestedAt == referee.createdAt }, "rule 4: a verdict covers the text sent")
        let steps = attempts.flatMap { $0.proofAttempt?.sortedSteps ?? [] }
        #expect(steps.allSatisfy { ($0.latestRevision?.createdAt ?? .distantFuture) <= referee.createdAt },
                "every attempt's steps were written before the referee was asked, so its verdict covers them")
        #expect(verdicts[1].gapStepIndices == [2])
        #expect(referee.bodyLaTeX == "Judged.")
        #expect(referee.request?.parseState == .clean)
        #expect(threads.runs.isEmpty && threads.streamingBranchIDs.isEmpty)
        #expect(attempts[1].proofAttempt?.standingVerdict?.gapStepIndices == [2])
    }

    @Test("Stopping one attempt keeps the referee, which sees it marked partial")
    func cardStopKeepsReferee() async throws {
        let attempts = try sendFanOut()
        provider.send(to: 1, .started(answeredModel: "m", usage: TokenUsage(input: 10)),
                      .text(#"{"overview":"","steps":[{"establishes":"Cauchy","confidence":"routine","text":"Order $p$."},{"establ"#))
        try await waitUntil { threads.live[attempts[1].stableID]?.fullText.hasSuffix("establ") == true }
        threads.stop(messageID: attempts[1].stableID)
        try await waitUntil { threads.live[attempts[1].stableID] == nil }
        #expect(attempts[1].request?.parseState == .partial)
        #expect(attempts[1].proofAttempt?.parsedCleanly == false)
        #expect(attempts[1].proofAttempt?.sortedSteps.map(\.textLaTeX) == ["Order $p$."], "the complete step is kept")
        #expect(attempts[1].request?.rawOutput?.hasSuffix("establ") == true, "everything that arrived is kept")
        #expect(provider.requests.count == 2)

        provider.reply(to: 0, Self.attemptA)
        try await waitUntil { provider.requests.count == 3 }
        let text = try #require(provider.requests.last).turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(text.contains("[PARTIAL attempt by Model B, to judge: stopped before finishing]"))
        provider.reply(to: 2, refereeReport([("A", .complete, []), ("B", .complete, [])]))
        try await waitUntil { threads.live.isEmpty }
        let verdictB = try #require(attempts[1].proofAttempt?.verdicts?.first)
        #expect(verdictB.sawPartialAttempt)
    }

    @Test("Stop all cancels the waiting referee; Referee with C then starts it by hand, with the stopped attempts marked partial")
    func stopAllThenManual() async throws {
        let attempts = try sendFanOut()
        provider.send(to: 0, .text(#"{"overview":"Half"#))
        try await waitUntil { threads.live[attempts[0].stableID]?.fullText.isEmpty == false }
        threads.stop(branchID: branch.stableID)
        try await waitUntil { threads.live.isEmpty }
        try await Task.sleep(for: .milliseconds(20))
        #expect(provider.requests.count == 2, "no referee")
        #expect(threads.runs.isEmpty)
        let fanOut = try #require(branch.sortedMessages.first?.fanOut)

        try threads.referee(fanOut, with: c, problem: problem, branch: branch, effort: .low)
        #expect(provider.requests.count == 3)
        #expect(provider.requests.last?.effort == .low)
        let text = try #require(provider.requests.last).turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(text.contains("[PARTIAL attempt by Model A") && text.contains("[PARTIAL attempt by Model B"))
        #expect(throws: SendBlocker.busy) { try threads.referee(fanOut, with: c, problem: problem, branch: branch, effort: .low) }
    }

    @Test("Shared: provers take turns, and the later one is sent the earlier attempt")
    func sharedRunsInTurn() async throws {
        let attempts = try sendFanOut(visibility: .shared, referee: false)
        #expect(provider.requests.count == 1, "B waits")
        #expect(threads.live[attempts[1].stableID]?.phase == .queued)
        #expect(attempts[1].request?.contextText.isEmpty == true, "nothing sent to B yet")
        let first = provider.requests[0].turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(!first.contains("[Attempt by"))
        threads.reconcileOrphans(in: branch)
        #expect(!attempts[1].interrupted, "a waiting attempt is not an orphan")

        provider.reply(to: 0, Self.attemptA)
        try await waitUntil { provider.requests.count == 2 }
        let second = provider.requests[1].turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(second.contains("[Attempt by Model A]"))
        #expect(second.contains("Since $p < q$, $n_q = 1$."))
        #expect(second.contains("Prove that $G$ is cyclic."), "the prompt stays with the attempts it asked for")
        #expect(attempts[1].request?.contextText.contains("[Attempt by Model A]") == true)
        let sentA = try #require(attempts[0].request?.createdAt)
        #expect(try #require(attempts[1].request?.createdAt) > sentA, "B's record says when B was actually sent")
    }

    @Test("Attempts that failed or were cut off reach the referee marked partial, read as far as they go")
    func failedAndCutOffArePartial() async throws {
        let attempts = try sendFanOut()
        provider.send(to: 0, .text(String(Self.attemptA.dropLast(3))), .finished(.maxTokens, TokenUsage(input: 10, output: 9)))
        provider.fail(at: 1, ProviderError.overloaded("Overloaded"))
        try await waitUntil { provider.requests.count == 3 }
        #expect(attempts[0].request?.parseState == .partial)
        #expect(attempts[0].proofAttempt?.sortedSteps.count == 1)
        let text = try #require(provider.requests.last).turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(text.contains("[PARTIAL attempt by Model A, to judge: cut off at the output limit]"))
        #expect(text.contains("[PARTIAL attempt by Model B, to judge: ended with an error before finishing]"))
    }

    @Test("An attempt that ends unreadable keeps its text as written, with no steps")
    func unreadableAttempt() async throws {
        let attempts = try sendFanOut(referee: false)
        provider.reply(to: 0, "Here is my proof in prose instead.")
        try await waitUntil { threads.live[attempts[0].stableID] == nil }
        #expect(attempts[0].request?.parseState == .unstructured)
        #expect(attempts[0].bodyLaTeX == "Here is my proof in prose instead.")
        #expect(attempts[0].proofAttempt?.steps?.isEmpty ?? true)
        #expect(attempts[0].proofAttempt?.parsedCleanly == false)
    }

    @Test("Invariant 15 mid-run: a provider disallowed while a shared fan-out runs sends nothing more, and says so")
    func policyRevokedMidRun() async throws {
        let attempts = try sendFanOut(visibility: .shared)
        problems.setProvider(ProviderID.anthropic, allowed: false, for: problem)
        provider.reply(to: 0, Self.attemptA)
        try await waitUntil { threads.streamingBranchIDs.isEmpty }
        #expect(provider.requests.count == 1, "neither B nor the referee was sent")
        #expect(attempts[1].request?.errorKind == "not_sent")
        #expect(attempts[1].request?.errorMessage == "This problem does not allow sending to Anthropic.")
        let fanOut = try #require(branch.sortedMessages.first?.fanOut)
        #expect(threads.refereeNotices[fanOut.stableID] == "This problem does not allow sending to Anthropic.")
        #expect(threads.runs.isEmpty)
    }

    @Test("Refereeing again judges the attempts afresh: neither the first verdicts nor a later reply about them are sent")
    func refereeAgainIsFresh() async throws {
        _ = try sendFanOut()
        provider.reply(to: 0, Self.attemptA)
        provider.reply(to: 1, Self.attemptB)
        try await waitUntil { provider.requests.count == 3 }
        provider.reply(to: 2, refereeReport([("A", .complete, []), ("B", .gap, [2])]))
        try await waitUntil { threads.live.isEmpty }

        let draft = threads.draft(for: branch.stableID)
        draft.text = "Why does B fail?"
        draft.selection = SendSelection(recipients: [a.stableID])
        try threads.send(problem: problem, branch: branch, draft: draft)
        provider.reply(to: 3, "THE REFEREE FOUND A GAP AT B'S STEP 2.")
        try await waitUntil { threads.live.isEmpty }

        let fanOut = try #require(branch.sortedMessages.first?.fanOut)
        try threads.referee(fanOut, with: c, problem: problem, branch: branch, effort: .high)
        let text = try #require(provider.requests.last).turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(!text.contains("Verdict on Model"))
        #expect(!text.contains("THE REFEREE FOUND A GAP"))
        #expect(!text.contains("Why does B fail?"))
        #expect(text.contains("[Attempt by Model B, to judge]"))
    }

    @Test("Independent provers are all sent at once, before any attempt exists, so none can see another's")
    func independentStaysApart() throws {
        _ = try sendFanOut(referee: false)
        #expect(provider.requests.count == 2, "both requests were made at send")
        for request in provider.requests {
            #expect(!request.turns.flatMap(\.blocks).joined().contains("[Attempt by"))
        }
    }

    @Test("Stopping a waiting prover sends it nothing; the referee still follows and is told")
    func stopQueuedMember() async throws {
        let attempts = try sendFanOut(visibility: .shared)
        threads.stop(messageID: attempts[1].stableID)
        #expect(threads.live[attempts[1].stableID] == nil)
        #expect(attempts[1].interrupted)
        #expect(attempts[1].request?.contextText.isEmpty == true)
        provider.reply(to: 0, Self.attemptA)
        try await waitUntil { provider.requests.count == 2 }
        #expect(provider.requests[1].format == .refereeVerdicts(letters: ["A", "B"]), "B was never sent; the referee is next")
        let text = provider.requests[1].turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(text.contains("[PARTIAL attempt by Model B, to judge: stopped before finishing]\n(no text arrived)"))
        provider.reply(to: 1, refereeReport([("A", .complete, []), ("B", .complete, [])]))
        try await waitUntil { threads.live.isEmpty }
        let verdictB = try #require(attempts[1].proofAttempt?.verdicts?.first)
        #expect(verdictB.sawPartialAttempt)
        #expect(verdictB.outcome == .gap, "nothing arrived, so a complete verdict on it fails closed")
    }

    @Test("Unreadable referee output is kept as written, with no verdicts")
    func unreadableReferee() async throws {
        let attempts = try sendFanOut(provers: [a])
        provider.reply(to: 0, Self.attemptA)
        try await waitUntil { provider.requests.count == 2 }
        provider.reply(to: 1, "Both attempts look fine to me.")
        try await waitUntil { threads.live.isEmpty }
        let referee = try #require(branch.sortedMessages.last)
        #expect(referee.request?.parseState == .unstructured)
        #expect(referee.bodyLaTeX == "Both attempts look fine to me.")
        #expect(attempts[0].proofAttempt?.verdicts?.isEmpty ?? true)
    }

    @Test("One prover and a referee is a fan-out; one prover alone is a prose reply")
    func whatMakesAFanOut() async throws {
        let attempts = try sendFanOut(provers: [a])
        #expect(attempts.count == 1)
        #expect(provider.requests.first?.format == .attempt)
        threads.stop(branchID: branch.stableID)
        try await waitUntil { threads.streamingBranchIDs.isEmpty }
        let draft = threads.draft(for: branch.stableID)
        draft.text = "And in words?"
        draft.selection = SendSelection(recipients: [a.stableID])
        try threads.send(problem: problem, branch: branch, draft: draft)
        #expect(branch.sortedMessages.last?.kind == .reply)
        #expect(provider.requests.last?.format == nil)
        #expect(branch.sortedMessages.last?.request?.promptVersion == "prover@2")
    }

    @Test("Quitting reads what arrived at once and starts no referee")
    func quit() async throws {
        let attempts = try sendFanOut()
        // Cut inside the second step.
        let partial = String(Self.attemptA.dropLast(3))
        provider.send(to: 0, .text(partial))
        try await waitUntil { threads.live[attempts[0].stableID]?.fullText == partial }
        threads.stopAllForQuit()
        #expect(threads.live.isEmpty && threads.runs.isEmpty)
        #expect(attempts[0].request?.parseState == .partial, "read at once, leniently: the complete step is kept")
        #expect(attempts[0].proofAttempt?.sortedSteps.count == 1)
        #expect(attempts[0].request?.stopReason == LocalStopReason.appQuit.rawValue)
        try await Task.sleep(for: .milliseconds(20))
        #expect(provider.requests.count == 2)
    }

    @Test("Deleting the problem mid-fan-out forgets its runs and writes nothing")
    func deleteMidFanOut() async throws {
        _ = try sendFanOut()
        problems.delete(problem)
        #expect(threads.runs.isEmpty && threads.live.isEmpty)
        try await waitUntil { provider.terminatedCount == 2 }
        saves.flush()
        #expect(saves.lastError == nil)
        #expect(try context.fetchCount(FetchDescriptor<FanOut>()) == 0)
    }

    @Test("The plan for a fan-out: per model, the referee's ceiling, and the send label")
    func plan() throws {
        let draft = threads.draft(for: branch.stableID)
        draft.text = "Prove it."
        draft.selection = SendSelection(recipients: [a.stableID, b.stableID], refereeSlotID: c.stableID)
        let plan = threads.plan(problem: problem, branch: branch, draft: draft)
        #expect(plan.kind == .fanOut(.independent))
        #expect(plan.blocker == nil)
        #expect(plan.recipients.map(\.letter) == ["A", "B"])
        #expect(plan.referee?.letter == "C")
        #expect(abs((plan.outputCeiling ?? 0) - 3 * 1.28) < 1e-9)
        #expect(plan.sendLabel == "Send to A, B, then C")
        #expect(plan.recipients.allSatisfy { $0.totalTokens != nil })
        draft.text = ""
        #expect(threads.plan(problem: problem, branch: branch, draft: draft).blocker == .emptyMessage,
                "an empty draft still gets an estimate")
        problems.setRole(.scout, for: a)
        problems.setRole(.scout, for: b)
        #expect(threads.plan(problem: problem, branch: branch, draft: draft).blocker == .noProver)
    }

    @Test("Slots: the next free letter; editing a slot never relabels what it wrote")
    func slotEdits() async throws {
        #expect(problem.sortedModelSlots.map(\.letter) == ["A", "B", "C"])
        let revision = problems.contextRevisions[problem.stableID]
        problems.setRole(.referee, for: b)
        #expect(problems.contextRevisions[problem.stableID] != revision, "the composer's estimate refreshes")

        let draft = threads.draft(for: branch.stableID)
        draft.text = "Is it cyclic?"
        draft.selection = SendSelection(recipients: [a.stableID])
        try threads.send(problem: problem, branch: branch, draft: draft)
        provider.reply(to: 0, "Yes.")
        try await waitUntil { threads.live.isEmpty }
        let reply = try #require(branch.sortedMessages.last)
        problems.setRole(.referee, for: a)
        let authors = AuthorDirectory(problem: problem, people: [problems.me()], catalog: .standard)
        #expect(authors.attribution(of: reply)?.role == .prover)
        #expect(authors.attribution(of: reply)?.modelName == "Claude Opus 5.5")

        draft.text = "And why?"
        problems.setRole(.prover, for: b)
        draft.selection = SendSelection(recipients: [b.stableID])
        try threads.send(problem: problem, branch: branch, draft: draft)
        let context = try #require(provider.requests.last).turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(context.contains("[Model A · prover]"), "the reply is labelled with the role it was written in")
    }
}

@Suite("Fan-out through the wire")
struct FanOutWireTests {
    @Test("Invariant 1: a whole fan-out and referee pass on the example changes no statement, status or review")
    func refereeGrantsNothing() async throws {
        let fixture = PreviewFixtures.make(services: .demo, demoPause: .zero)
        let people = fixture.state.problems.personIDs()
        // Every statement with its own and displayed status, its text and what it uses.
        func statuses() -> [String] {
            let state = StatementGraphState.read(problem: fixture.problem, people: people)
            return state.nodes.map {
                "\($0.label) \($0.derived.own) \($0.derived.displayed) \($0.statementLaTeX) uses \($0.uses.map(state.label(of:)))"
            }
        }
        let context = fixture.state.container.mainContext
        let before = statuses()
        let reviews = try context.fetchCount(FetchDescriptor<Review>())
        let comments = try context.fetchCount(FetchDescriptor<StepComment>())
        func personRevisions() throws -> Int {
            try context.fetch(FetchDescriptor<StepRevision>()).filter { $0.author?.isHuman == true }.count
        }
        let revisions = try personRevisions()
        fixture.scheduleSend("Prove Theorem 1 again.", fanOut: .independent)
        try await waitUntil(timeout: .seconds(10)) {
            fixture.mainBranch.sortedMessages.filter { $0.kind == .referee }.count == 2 && fixture.state.threads.live.isEmpty
        }
        #expect((fixture.fanOut.verdicts ?? []).count == 2, "the old fan-out's verdicts are untouched")
        #expect(statuses() == before)
        #expect(try context.fetchCount(FetchDescriptor<Review>()) == reviews)
        #expect(try context.fetchCount(FetchDescriptor<StepComment>()) == comments)
        #expect(try personRevisions() == revisions, "a model's output never writes a revision in a person's name")
    }

    @Test("The demo transport end to end: two attempts read as steps, the referee's verdicts stored")
    func demoFanOut() async throws {
        let state = AppState(storage: .inMemory, secrets: InMemorySecretStore([AnthropicProvider.keyAccount: "demo"]),
                             transport: DemoTransport(pause: .zero))
        let problem = state.problems.createProblem(title: "P", statementLaTeX: "Let $|G| = p^2 q$.")
        state.problems.setProvider(ProviderID.anthropic, allowed: true, for: problem)
        let a = state.problems.addSlot(to: problem, providerID: ProviderID.anthropic, modelID: "claude-opus-5-5")
        let b = state.problems.addSlot(to: problem, providerID: ProviderID.anthropic, modelID: "claude-opus-5-5")
        let c = state.problems.addSlot(to: problem, providerID: ProviderID.anthropic, modelID: "claude-opus-5-5", role: .referee)
        let branch = problem.sortedBranches[0]
        let draft = state.threads.draft(for: branch.stableID)
        draft.text = "Prove Theorem 1."
        draft.selection = SendSelection(recipients: [a.stableID, b.stableID], refereeSlotID: c.stableID)
        try state.threads.send(problem: problem, branch: branch, draft: draft)
        try await waitUntil(timeout: .seconds(10)) {
            branch.sortedMessages.last?.kind == .referee && state.threads.live.isEmpty
        }
        let attempts = branch.sortedMessages.filter { $0.kind == .attempt }
        #expect(attempts.allSatisfy { $0.request?.parseState == .clean })
        #expect(Set(attempts.compactMap { $0.proofAttempt?.sortedSteps.count }) == [5, 4])
        let verdicts = attempts.compactMap { $0.proofAttempt?.standingVerdict }
        #expect(verdicts.map(\.outcome).sorted { $0.rawValue < $1.rawValue } == [.complete, .gap])
        #expect(branch.sortedMessages.last?.request?.parseState == .clean)
    }
}

@Suite("Thread items")
struct ThreadItemTests {
    @Test("A fan-out's prompt and attempts are one item, in order; the referee and everything else stand alone")
    func grouping() throws {
        let fixture = PreviewFixtures.make()
        let messages = fixture.mainBranch.sortedMessages
        let items = ThreadItem.make(messages)
        guard case .fanOut(let prompt, let fanOut, let attempts) = items.first else {
            Issue.record("the fan-out comes first")
            return
        }
        #expect(prompt.stableID == fixture.fanOutPrompt.stableID && fanOut.stableID == fixture.fanOut.stableID)
        #expect(attempts.map(\.stableID) == [fixture.messageA.stableID, fixture.messageB.stableID])
        #expect(items.count == messages.count - 2, "the two attempts are inside the fan-out's item")
        guard case .message(let next) = items[1] else {
            Issue.record("the referee follows as its own item")
            return
        }
        #expect(next.stableID == fixture.refereeMessage.stableID)
        let context = ThreadContext(problem: fixture.problem, branch: fixture.mainBranch, items: items, messages: messages,
                                    live: [:], runs: [:], notices: [:],
                                    authors: AuthorDirectory(problem: fixture.problem, people: [], catalog: .standard),
                                    busy: false)
        #expect(context.refereeFanOuts[fixture.refereeMessage.stableID]?.stableID == fixture.fanOut.stableID)
        #expect(context.refereeGaveVerdicts[fixture.fanOut.stableID] == true)
    }
}
