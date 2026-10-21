import Foundation
import SwiftData
import Testing
@testable import sangaku

@Suite("Thread manager")
struct ThreadManagerTests {
    /// Held for the whole test: a `ModelContext` does not keep its container alive.
    private let container: ModelContainer
    private let saves: SaveScheduler
    private let problems: ProblemManager
    private let credentials: CredentialManager
    private let provider = ScriptedProvider()
    private let threads: ThreadManager
    private let problem: Problem
    private let branch: Branch

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
    }

    private func send(_ text: String = "Is the Sylow $q$-subgroup normal?") throws -> Message {
        let draft = threads.draft(for: branch.stableID)
        draft.text = text
        try threads.send(problem: problem, branch: branch, draft: draft)
        return try #require(branch.sortedMessages.last)
    }

    private var context: ModelContext { container.mainContext }

    @Test("A reply streams into its stream object only; the end writes it once, with usage and cost")
    func happyPath() async throws {
        let reply = try send()
        let prompt = branch.sortedMessages[0]
        #expect(prompt.author == .human(problems.me().personID))
        #expect(prompt.kind == .prompt)
        #expect(reply.author == .model(try #require(problem.sortedModelSlots.first).slotID))
        #expect(reply.kind == .reply)
        #expect(reply.derivedFromIDs == [prompt.stableID])
        #expect(threads.draft(for: branch.stableID).text.isEmpty, "the draft is cleared")
        let record = try #require(reply.request)
        #expect(record.contextText.contains("Let $|G| = pq$ with $p < q$."))
        #expect(record.contextText.hasSuffix("Is the Sylow $q$-subgroup normal?"))
        #expect(record.promptVersion == "prover@2")
        #expect(record.finishedAt == nil)
        #expect(threads.streamingBranchIDs == [branch.stableID])

        saves.flush()
        #expect(!context.hasChanges)
        provider.send(.started(answeredModel: "claude-opus-5-5", usage: TokenUsage(input: 20, cacheRead: 900)), .thinking)
        for _ in 0..<200 { provider.send(.text("ab")) }
        try await waitUntil { threads.live[reply.stableID]?.fullText.count == 400 }
        #expect(reply.bodyLaTeX.isEmpty, "no store write per token")
        #expect(!context.hasChanges, "streaming never dirties the store")

        // A save mid-stream keeps an unfinished request, which reads as interrupted, never as complete.
        let other = ModelContext(container)
        let id = reply.stableID
        let saved = try #require(try other.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.stableID == id })).first)
        #expect(saved.outcome(isStreaming: false) == .interrupted)

        let usage = TokenUsage(input: 20, cacheRead: 900, output: 450)
        provider.send(.finished(.endTurn, usage))
        try await waitUntil { threads.live.isEmpty }
        #expect(reply.bodyLaTeX == String(repeating: "ab", count: 200))
        #expect(!reply.interrupted)
        #expect(record.usageReported)
        #expect(record.usage == usage)
        #expect(record.answeredModelID == "claude-opus-5-5")
        #expect(record.stopReason == "end_turn")
        #expect(record.finishedAt != nil)
        #expect(record.estimatedCost == ModelCatalog.cost(usage, .known(ModelCatalog.claudeOpus55)))
        #expect(reply.outcome(isStreaming: false) == .complete)
        #expect(threads.streamingBranchIDs.isEmpty)
        #expect(context.hasChanges)
    }

    @Test("The request is built from the context: stable part with one breakpoint, the effort chosen")
    func requestShape() throws {
        threads.draft(for: branch.stableID).effort = .max
        _ = try send()
        let request = try #require(provider.requests.first)
        #expect(request.modelID == "claude-opus-5-5")
        #expect(request.effort == .max)
        #expect(request.maxOutputTokens == ThreadManager.maxOutputTokens)
        #expect(request.system.count == ContextSectionKind.allCases.count)
        #expect(request.system.filter(\.cacheBreakpoint).count == 1 && request.system.last?.cacheBreakpoint == true)
        #expect(request.turns.last?.role == .user)
    }

    @Test("Stop keeps what arrived, marks it interrupted, ends the request and ignores late events")
    func stop() async throws {
        let reply = try send()
        provider.send(.started(answeredModel: "claude-opus-5-5", usage: TokenUsage(input: 30)), .text("Partial $n_q"))
        try await waitUntil { threads.live[reply.stableID]?.fullText == "Partial $n_q" }
        threads.stop(messageID: reply.stableID)
        #expect(reply.bodyLaTeX == "Partial $n_q")
        #expect(reply.interrupted)
        #expect(reply.request?.stopReason == "stopped")
        #expect(reply.request?.usageReported == false)
        #expect(reply.request?.inputTokens == 30)
        #expect(reply.request?.outputTokens == 0, "output so far is not reported, so it is not recorded")
        #expect(reply.outcome(isStreaming: false) == .interrupted)
        try await waitUntil { provider.terminatedCount == 1 }
        provider.send(.text(" late"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(reply.bodyLaTeX == "Partial $n_q")
        #expect(threads.live.isEmpty && threads.streamingBranchIDs.isEmpty)
    }

    @Test("Stop before anything arrives keeps an empty, interrupted reply")
    func stopEarly() throws {
        let reply = try send()
        threads.stop(branchID: branch.stableID)
        #expect(reply.bodyLaTeX.isEmpty)
        #expect(reply.interrupted)
        #expect(threads.live.isEmpty)
    }

    @Test("An error mid-stream keeps the partial text and says what failed")
    func midStreamError() async throws {
        let reply = try send()
        provider.send(.text("Half a proof"))
        try await waitUntil { threads.live[reply.stableID]?.fullText == "Half a proof" }
        provider.fail(ProviderError.overloaded("Overloaded"))
        try await waitUntil { threads.live.isEmpty }
        #expect(reply.bodyLaTeX == "Half a proof")
        #expect(reply.interrupted)
        #expect(reply.request?.errorKind == "overloaded_error")
        #expect(reply.outcome(isStreaming: false) == .failed(kind: "overloaded_error", message: ProviderError.overloaded("Overloaded").message))
    }

    @Test("A request refused before streaming records the error and no text")
    func refusedRequest() async throws {
        let reply = try send()
        provider.fail(ProviderError.http(status: 401, kind: "authentication_error", message: "invalid x-api-key", retryAfter: nil))
        try await waitUntil { threads.live.isEmpty }
        #expect(reply.bodyLaTeX.isEmpty)
        #expect(!reply.interrupted)
        #expect(reply.request?.errorKind == "authentication_error")
        #expect(reply.request?.estimatedCost == 0)
    }

    @Test("A stream that ends without finishing is a failure, not a complete reply")
    func endsEarly() async throws {
        let reply = try send()
        provider.send(.text("cut"))
        provider.end()
        try await waitUntil { threads.live.isEmpty }
        #expect(reply.request?.errorKind == "incomplete")
        #expect(reply.interrupted)
    }

    @Test("A declined request is shown as declined, nothing else answers, and later context leaves it out")
    func declined() async throws {
        let reply = try send()
        provider.send(.text("I can't"), .finished(.refusal(category: "cyber"), TokenUsage(input: 10, output: 3)))
        try await waitUntil { threads.live.isEmpty }
        #expect(reply.outcome(isStreaming: false) == .declined(category: "cyber"))
        #expect(!reply.interrupted)
        #expect(provider.requests.count == 1, "no fallback model")
        _ = try send("Try again, differently.")
        let second = try #require(provider.requests.last)
        #expect(!second.turns.flatMap(\.blocks).contains { $0.contains("I can't") })
    }

    @Test("Invariant 15: a problem that does not allow the provider sends nothing and changes nothing")
    func disallowedProvider() throws {
        problems.setProvider(ProviderID.anthropic, allowed: false, for: problem)
        let draft = threads.draft(for: branch.stableID)
        draft.text = "Hello"
        #expect(throws: SendBlocker.providerNotAllowed(providerID: ProviderID.anthropic, providerName: "Anthropic")) {
            try threads.send(problem: problem, branch: branch, draft: draft)
        }
        #expect(branch.messages?.isEmpty ?? true)
        #expect(problem.modelSlots?.isEmpty ?? true, "no slot is created")
        #expect(provider.requests.isEmpty)
        #expect(draft.text == "Hello", "the draft is kept")
        let plan = threads.plan(problem: problem, branch: branch, draft: draft)
        #expect(plan.sections.isEmpty, "no estimate is built for a provider that is not allowed")
    }

    @Test("Without a stored key, Send says so instead of sending")
    func missingKey() async throws {
        await credentials.refresh(ProviderID.anthropic)
        let draft = threads.draft(for: branch.stableID)
        draft.text = "Hello"
        #expect(throws: SendBlocker.missingKey(providerName: "Anthropic")) {
            try threads.send(problem: problem, branch: branch, draft: draft)
        }
        #expect(provider.requests.isEmpty)
    }

    @Test("One reply at a time per branch; the slot is created once and reused")
    func busyAndSlot() async throws {
        let first = try send()
        let draft = threads.draft(for: branch.stableID)
        draft.text = "And another?"
        #expect(throws: SendBlocker.busy) { try threads.send(problem: problem, branch: branch, draft: draft) }
        provider.send(.finished(.endTurn, TokenUsage()))
        try await waitUntil { threads.live.isEmpty }
        #expect(first.request?.finishedAt != nil)
        _ = try send("And another?")
        #expect(problem.modelSlots?.count == 1)
        #expect(problem.sortedModelSlots.first?.letter == "A")
        #expect(problem.sortedModelSlots.first?.colorTokenRaw == ColorToken.modelA.rawValue)
    }

    @Test("Deleting a problem mid-stream ends its request and writes nothing into deleted records")
    func deleteMidStream() async throws {
        _ = try send()
        provider.send(.text("Partial"))
        problems.delete(problem)
        try await waitUntil { provider.terminatedCount == 1 }
        provider.send(.finished(.endTurn, TokenUsage()))
        try await Task.sleep(for: .milliseconds(30))
        #expect(threads.live.isEmpty && threads.streamingBranchIDs.isEmpty)
        saves.flush()
        #expect(saves.lastError == nil)
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RequestRecord>()) == 0)
    }

    @Test("Quitting keeps every live reply as interrupted, once")
    func quit() async throws {
        let reply = try send()
        provider.send(.text("So far"))
        try await waitUntil { threads.live[reply.stableID]?.fullText == "So far" }
        threads.stopAllForQuit()
        threads.stopAllForQuit()
        #expect(reply.bodyLaTeX == "So far")
        #expect(reply.interrupted)
        #expect(reply.request?.stopReason == "app_quit")
    }

    @Test("A request that never finished (the app quit or crashed) becomes interrupted and says so")
    func orphans() throws {
        let orphan = Message(author: .model(ModelSlotID(UUID())), kind: .reply)
        orphan.request = RequestRecord()
        branch.messages = (branch.messages ?? []) + [orphan]
        threads.reconcileOrphans(in: branch)
        #expect(orphan.interrupted)
        #expect(orphan.request?.stopReason == "orphaned")
        #expect(orphan.request?.finishedAt != nil)
    }

    @Test("The draft survives switching away and back")
    func draftPersists() {
        threads.draft(for: branch.stableID).text = "Half-written"
        #expect(threads.draft(for: branch.stableID).text == "Half-written")
        #expect(threads.draft(for: UUID()).text.isEmpty)
    }

    @Test("The plan estimates locally, prices the stable part as cached or written, and learns from real counts")
    func plan() async throws {
        let draft = threads.draft(for: branch.stableID)
        draft.text = "Is it cyclic?"
        let before = threads.plan(problem: problem, branch: branch, draft: draft)
        let first = try #require(before.recipients.first)
        #expect(before.blocker == nil)
        #expect(before.kind == .reply)
        #expect(first.letter == "A" && first.slotID == nil, "slot A is created on first send")
        #expect(before.sendLabel == "Send to A")
        #expect(before.sections.count == ContextSectionKind.allCases.count)
        #expect(!first.calibrated)
        if case .fits = first.fit {} else { Issue.record("expected the context to fit") }
        if case .range(let low, let high) = first.cost { #expect(low < high) } else { Issue.record("expected a range") }
        #expect(abs((first.outputCeiling ?? 0) - 1.28) < 1e-9, "64,000 output tokens at $20 per million")

        let reply = try send()
        let estimated = try #require(reply.request?.estimatedInputTokens)
        provider.send(.finished(.endTurn, TokenUsage(input: estimated * 2)))
        try await waitUntil { threads.live.isEmpty }
        draft.text = "Is it cyclic?"
        let after = threads.plan(problem: problem, branch: branch, draft: draft)
        #expect(after.recipients.first?.calibrated == true)
        #expect(after.recipients.first?.slotID == problem.sortedModelSlots.first?.stableID)
    }

    @Test("Invariant 5 end to end: what a small window leaves out is recorded, told to the model and listed in the plan")
    func dropsAreRecorded() throws {
        let tiny = ModelInfo(id: "tiny-window", providerID: ProviderID.anthropic, displayName: "Tiny",
                             contextWindow: ThreadManager.maxOutputTokens + 1_400,
                             maxOutputTokens: ThreadManager.maxOutputTokens, minimumCacheablePrefix: 512,
                             pricing: ModelCatalog.claudeOpus55.pricing)
        let small = ThreadManager(context: context, saves: saves, problems: problems, credentials: credentials,
                                  registry: ProviderRegistry([provider]), catalog: ModelCatalog(models: [tiny]))
        let slot = problems.addSlot(to: problem, providerID: ProviderID.anthropic, modelID: tiny.id)
        for i in 0..<8 {
            let question = Message(author: .human(problems.me().personID),
                                   bodyLaTeX: "Question \(i): " + String(repeating: "q ", count: 600), kind: .prompt)
            question.createdAt = Date(timeIntervalSinceReferenceDate: Double(2 * i))
            let answer = Message(author: .model(slot.slotID),
                                 bodyLaTeX: "Answer \(i): " + String(repeating: "a ", count: 600), kind: .reply)
            answer.createdAt = Date(timeIntervalSinceReferenceDate: Double(2 * i + 1))
            branch.messages = (branch.messages ?? []) + [question, answer]
        }
        let draft = small.draft(for: branch.stableID)
        draft.text = "Summarise."
        let plan = small.plan(problem: problem, branch: branch, draft: draft)
        #expect(!plan.dropped.isEmpty, "the composer lists what will be left out")
        try small.send(problem: problem, branch: branch, draft: draft)
        let record = try #require(branch.sortedMessages.last?.request)
        #expect(record.droppedItems == plan.dropped)
        #expect(record.contextText.contains(ContextBuilder.droppedConversationNotice))
        #expect(!record.contextText.contains("Question 0:"))
        small.stop(branchID: branch.stableID)

        let tinier = ThreadManager(context: context, saves: saves, problems: problems, credentials: credentials,
                                   registry: ProviderRegistry([provider]),
                                   catalog: ModelCatalog(models: [ModelInfo(
                                       id: tiny.id, providerID: ProviderID.anthropic, displayName: "Tinier",
                                       contextWindow: ThreadManager.maxOutputTokens + 100,
                                       maxOutputTokens: ThreadManager.maxOutputTokens, minimumCacheablePrefix: 512,
                                       pricing: tiny.pricing)]))
        let count = branch.messages?.count
        let tinierDraft = tinier.draft(for: branch.stableID)
        tinierDraft.text = "Summarise."
        do {
            try tinier.send(problem: problem, branch: branch, draft: tinierDraft)
            Issue.record("a window too small for the essentials must refuse")
        } catch {
            guard case .context(.essentialsDoNotFit) = error else { throw error }
        }
        #expect(branch.messages?.count == count, "a refused send writes nothing")
    }

    @Test("A slot with an unknown model shows an unknown price and window, never 0")
    func unknownModel() throws {
        let slot = problems.addSlot(to: problem, providerID: ProviderID.anthropic, modelID: "claude-opus-5-5")
        problems.setModel("prover-x", for: slot)
        let draft = threads.draft(for: branch.stableID)
        draft.text = "Hello"
        let plan = threads.plan(problem: problem, branch: branch, draft: draft)
        #expect(plan.recipients.first?.cost == .unknown(modelID: "prover-x"))
        #expect(plan.recipients.first?.outputCeiling == nil)
        #expect(plan.inputCost == .unknown(modelID: "prover-x"))
        #expect(plan.outputCeiling == nil, "an unknown price is never added up as 0")
        if case .unknownWindow? = plan.recipients.first?.fit {} else { Issue.record("expected an unknown window") }
    }
}

@Suite("Message stream")
struct MessageStreamTests {
    @Test("Text is published at most once per interval, with a trailing update and a final flush")
    func throttles() async throws {
        let stream = MessageStream(interval: .milliseconds(200))
        stream.apply(.started(answeredModel: "m", usage: TokenUsage(input: 5)))
        #expect(stream.phase == .connecting)
        stream.apply(.thinking)
        #expect(stream.phase == .thinking)
        stream.apply(.text("a"))
        #expect(stream.text == "a", "the first delta shows at once")
        #expect(stream.phase == .writing)
        stream.apply(.text("b"))
        stream.apply(.text("c"))
        #expect(stream.text == "a", "later deltas wait for the interval")
        #expect(stream.fullText == "abc", "nothing is lost meanwhile")
        try await waitUntil { stream.text == "abc" }
        stream.apply(.text("d"))
        stream.flush()
        #expect(stream.text == "abcd")
        stream.apply(.text("e"))
        stream.apply(.finished(.endTurn, TokenUsage(input: 5, output: 9)))
        #expect(stream.text == "abcde", "the end publishes everything")
        #expect(stream.usage == TokenUsage(input: 5, output: 9))
        #expect(stream.answeredModel == "m")
    }
}

@Suite("Keys and wiring")
struct KeyAndWiringTests {
    @Test("Creating the credential manager touches no store; saving trims, refuses blanks, and removing forgets")
    func credentials() async throws {
        let store = SpySecretStore()
        let credentials = CredentialManager(store: store)
        #expect(store.calls == 0, "nothing is read at launch")
        #expect(credentials.state(for: ProviderID.anthropic) == .unknown)
        await #expect(throws: CredentialError.self) { try await credentials.save("   ", for: ProviderID.anthropic) }
        try await credentials.save("  sk-test-key \n", for: ProviderID.anthropic)
        #expect(try await store.read(AnthropicProvider.keyAccount) == "sk-test-key")
        #expect(credentials.state(for: ProviderID.anthropic) == .stored)
        try await credentials.remove(for: ProviderID.anthropic)
        #expect(credentials.state(for: ProviderID.anthropic) == .missing)
        await credentials.refresh(ProviderID.anthropic)
        #expect(credentials.state(for: ProviderID.anthropic) == .missing)
    }

    @Test("The in-memory app never reaches the network or the Keychain")
    func inMemoryAppIsOffline() async throws {
        let state = AppState(storage: .inMemory, secrets: InMemorySecretStore([AnthropicProvider.keyAccount: "k"]))
        let problem = state.problems.createProblem(title: "P", statementLaTeX: "x")
        state.problems.setProvider(ProviderID.anthropic, allowed: true, for: problem)
        let branch = problem.sortedBranches[0]
        let draft = state.threads.draft(for: branch.stableID)
        draft.text = "Hello"
        try state.threads.send(problem: problem, branch: branch, draft: draft)
        try await waitUntil { state.threads.live.isEmpty }
        #expect(branch.sortedMessages.last?.request?.errorKind == "network")
    }

    @Test("The key reaches the request header and nothing that is stored")
    func keyNeverStored() async throws {
        let transport = FakeTransport(body: SSE.reply("Fine."))
        let state = AppState(storage: .inMemory, secrets: InMemorySecretStore([AnthropicProvider.keyAccount: "sk-test-SENTINEL"]),
                             transport: transport)
        let problem = state.problems.createProblem(title: "P", statementLaTeX: "x")
        state.problems.setProvider(ProviderID.anthropic, allowed: true, for: problem)
        let branch = problem.sortedBranches[0]
        let draft = state.threads.draft(for: branch.stableID)
        draft.text = "Hello"
        try state.threads.send(problem: problem, branch: branch, draft: draft)
        try await waitUntil { state.threads.live.isEmpty }
        let reply = try #require(branch.sortedMessages.last)
        let record = try #require(reply.request)
        #expect(reply.bodyLaTeX == "Fine.")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "x-api-key") == "sk-test-SENTINEL")
        for stored in [record.contextText, String(decoding: record.parametersJSON ?? Data(), as: UTF8.self),
                       reply.bodyLaTeX, record.errorMessage ?? ""] {
            #expect(!stored.contains("SENTINEL"))
        }
    }

    @Test("Fixture launch flags choose where requests go; only the explicit live flag reaches the real Keychain and network")
    func fixtureServices() {
        typealias Services = PreviewFixtures.Services
        #expect(Services.from(arguments: ["sangaku"]) == nil)
        #expect(Services.from(arguments: ["sangaku", "-SangakuFixture", "YES"]) == .offline)
        #expect(Services.from(arguments: ["sangaku", "-SangakuFixture", "YES", "-SangakuDemoReplies", "YES"]) == .demo)
        #expect(Services.from(arguments: ["sangaku", "-SangakuFixtureLive", "YES"]) == .live)
        #expect(Services.from(arguments: ["sangaku", "-SangakuDemoReplies", "YES"]) == nil, "demo replies alone open no fixture")
        #expect(Services.from(arguments: ["sangaku", "-SangakuFixtureVerified", "YES"]) == .offline,
                "the verification example opens on its own, offline")
    }

    @Test("Provider policy: a new problem allows nothing; setting it is idempotent")
    func policy() throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let problems = ProblemManager(context: container.mainContext,
                                      saves: SaveScheduler(context: container.mainContext, delay: .seconds(60)))
        let problem = problems.createProblem()
        #expect(problem.allowedProviderIDs.isEmpty)
        #expect(!problems.allows(ProviderID.anthropic, for: problem))
        problems.setProvider(ProviderID.anthropic, allowed: true, for: problem)
        problems.setProvider(ProviderID.anthropic, allowed: true, for: problem)
        #expect(problem.allowedProviderIDs == [ProviderID.anthropic])
        problems.setProvider(ProviderID.anthropic, allowed: false, for: problem)
        #expect(problem.allowedProviderIDs.isEmpty)
    }
}
