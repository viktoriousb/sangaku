import Foundation
import SwiftData
import Testing
@testable import sangaku

/// Alignment requests over the example, driven by a scripted provider.
@Suite("Alignment requests")
struct AlignmentRunTests {
    private let fixture = PreviewFixtures.make()
    private let provider = ScriptedProvider()
    private let threads: ThreadManager

    init() {
        threads = ThreadManager(context: fixture.state.container.mainContext, saves: fixture.state.saves,
                                problems: fixture.state.problems, credentials: CredentialManager(store: InMemorySecretStore()),
                                registry: ProviderRegistry([provider]))
    }

    private var context: ModelContext { fixture.state.container.mainContext }
    private var pair: ComparedPair { ComparedPair.oriented(fixture.attemptA.stableID, fixture.attemptB.stableID) }

    private func align() throws -> RequestRecord {
        let id = try threads.align(pair, aligner: fixture.slotC.stableID, problem: fixture.problem,
                                   branch: fixture.mainBranch, effort: .standard)
        return try #require(fixture.alignment.requests?.first { $0.stableID == id })
    }

    /// An answer pairing steps 1–5 by number, all equivalent, and step 6 of A alone.
    private var answer: String {
        let aIsFirst = pair.first == fixture.attemptA.stableID
        let rows = (1...5).map { #"{"label":"Step \#($0)","step_1":\#($0),"step_2":\#($0),"note":"","phrase_1":"","phrase_2":"","verdict":"equivalent"}"# }
            + [aIsFirst ? #"{"label":"Order 12","step_1":6,"step_2":0,"note":"","phrase_1":"","phrase_2":"","verdict":"only_1"}"#
                        : #"{"label":"Order 12","step_1":0,"step_2":6,"note":"","phrase_1":"","phrase_2":"","verdict":"only_2"}"#]
        return #"{"rows":[\#(rows.joined(separator: ","))],"summary":"They agree."}"#
    }

    @Test("An alignment is sent, stored on the comparison and nowhere else; corrections stay")
    func happyPath() async throws {
        let messages = fixture.mainBranch.sortedMessages.count
        let one = try #require(ComparisonState.read(fixture.attemptA, fixture.attemptB, in: fixture.problem,
                                                    people: fixture.state.problems.personIDs()).rows.first)
        try fixture.state.alignments.unpair(one.id, in: pair)
        let corrections = fixture.alignment.correctionsJSON

        let record = try align()
        #expect(provider.requests.count == 1 && provider.requests[0].format == .alignment)
        #expect(record.promptVersion == "aligner@2" && record.contextText.contains("[Attempt 1, to align]"))
        #expect(record.message == nil && fixture.mainBranch.sortedMessages.count == messages, "nothing enters the thread")
        #expect(threads.streamingBranchIDs == [fixture.mainBranch.stableID])
        #expect(throws: SendBlocker.busy) { try align() }

        provider.reply(to: 0, answer)
        try await waitUntil { threads.live.isEmpty }
        #expect(record.parseState == .clean && record.finishedAt != nil && record.usageReported)
        #expect(fixture.alignment.modelRunID == record.stableID && fixture.alignment.alignerSlotID == fixture.slotC.stableID)
        #expect(fixture.alignment.modelSummary == "They agree.")
        #expect(fixture.alignment.rows?.count == 6 && fixture.alignment.rows?.allSatisfy { $0.revisionAID != nil || $0.stepAID == nil } == true)
        #expect(fixture.alignment.correctionsJSON == corrections, "a person's corrections are never touched")
        let state = ComparisonState.read(fixture.attemptA, fixture.attemptB, in: fixture.problem,
                                         people: fixture.state.problems.personIDs())
        #expect(state[row: one.id] == nil, "the person's separation still stands over the new rows")
    }

    @Test("Invariant 1: storing an alignment changes no review, verdict or status")
    func grantsNothing() async throws {
        let graph = fixture.state.graph.state(for: fixture.problem)
        let reviews = try context.fetchCount(FetchDescriptor<Review>())
        let verdicts = try context.fetchCount(FetchDescriptor<RefereeVerdict>())
        _ = try align()
        provider.reply(to: 0, answer)
        try await waitUntil { threads.live.isEmpty }
        #expect(fixture.state.graph.state(for: fixture.problem) == graph)
        #expect(try context.fetchCount(FetchDescriptor<Review>()) == reviews)
        #expect(try context.fetchCount(FetchDescriptor<RefereeVerdict>()) == verdicts)
    }

    @Test("Stopped, failed or unreadable: the record says so and the comparison keeps its rows")
    func failsClosed() async throws {
        let rows = fixture.alignment.rowsJSON
        let stopped = try align()
        provider.send(to: 0, .started(answeredModel: "claude-opus-5-5", usage: TokenUsage(input: 40)), .text(#"{"rows":["#))
        try await Task.sleep(for: .milliseconds(20))
        threads.stop(messageID: stopped.stableID)
        #expect(stopped.stopReason == LocalStopReason.stopped.rawValue && stopped.parseState == .unstructured)
        #expect(stopped.rawOutput == #"{"rows":["#)

        let failed = try align()
        provider.fail(at: 1, ProviderError.overloaded("Overloaded"))
        try await waitUntil { threads.live.isEmpty }
        #expect(failed.errorKind != nil && failed.parseState == .unstructured)

        let garbled = try align()
        provider.reply(to: 2, #"{"rows":[{"label":"x"}],"summary":"?"}"#)
        try await waitUntil { threads.live.isEmpty }
        #expect(garbled.parseState == .unstructured)
        #expect(fixture.alignment.rowsJSON == rows && fixture.alignment.modelRunID == nil)
    }

    @Test("Invariant 15 and who may align: refusals write nothing and send nothing")
    func refusals() throws {
        let records = try context.fetchCount(FetchDescriptor<RequestRecord>())
        fixture.state.problems.setProvider(ProviderID.anthropic, allowed: false, for: fixture.problem)
        #expect(throws: SendBlocker.providerNotAllowed(providerID: ProviderID.anthropic, providerName: "Anthropic")) {
            try align()
        }
        fixture.state.problems.setProvider(ProviderID.anthropic, allowed: true, for: fixture.problem)
        func alignBy(_ slot: ModelSlot, _ pair: ComparedPair? = nil) throws {
            try threads.align(pair ?? self.pair, aligner: slot.stableID, problem: fixture.problem,
                              branch: fixture.mainBranch, effort: .standard)
        }
        #expect(throws: SendBlocker.compare(.noAligner), "a prover never aligns") { try alignBy(fixture.slotA) }
        fixture.slotA.role = .referee
        #expect(throws: SendBlocker.compare(.noAligner), "nor does a referee that wrote an attempt") {
            try alignBy(fixture.slotA)
        }
        #expect(throws: SendBlocker.compare(.notAPair)) {
            try alignBy(fixture.slotC, ComparedPair(first: fixture.attemptA.stableID, second: fixture.attemptA.stableID))
        }
        #expect(try context.fetchCount(FetchDescriptor<RequestRecord>()) == records)
        #expect(provider.requests.isEmpty)
    }

    @Test("Attempts passed the other way round are aligned in the order Compare shows them, and the answer is kept")
    func orientation() async throws {
        let reversed = ComparedPair(first: pair.second, second: pair.first)
        let id = try threads.align(reversed, aligner: fixture.slotC.stableID, problem: fixture.problem,
                                   branch: fixture.mainBranch, effort: .standard)
        let record = try #require(fixture.alignment.requests?.first { $0.stableID == id })
        provider.reply(to: 0, answer)
        try await waitUntil { threads.live.isEmpty }
        #expect(record.parseState == .clean && fixture.alignment.modelRunID == id)
        #expect(fixture.alignment.attemptAID == pair.first)
    }

    @Test("Invariant 4: while an attempt is still being written the branch is busy, and nothing is aligned")
    func attemptLive() throws {
        let draft = threads.draft(for: fixture.mainBranch.stableID)
        draft.selection = SendSelection(recipients: [fixture.slotA.stableID, fixture.slotB.stableID], refereeSlotID: nil)
        draft.text = "Prove Theorem 1 again."
        try threads.send(problem: fixture.problem, branch: fixture.mainBranch, draft: draft)
        let live = fixture.mainBranch.sortedMessages.filter { threads.live[$0.stableID] != nil }
            .compactMap(\.proofAttempt?.stableID)
        #expect(live.count == 2)
        #expect(throws: SendBlocker.busy) { try align() }
        #expect(throws: SendBlocker.busy) {
            try threads.align(ComparedPair(first: live[0], second: live[1]), aligner: fixture.slotC.stableID,
                              problem: fixture.problem, branch: fixture.mainBranch, effort: .standard)
        }
        #expect(provider.requests.allSatisfy { $0.format != .alignment })
    }

    @Test("Quitting, deleting the problem and orphans")
    func lifecycle() async throws {
        let quitting = try align()
        threads.stopAllForQuit()
        #expect(quitting.stopReason == LocalStopReason.appQuit.rawValue && threads.live.isEmpty)

        let dropped = try align()
        threads.cancelAll(problemID: fixture.problem.stableID)
        #expect(threads.live.isEmpty && dropped.finishedAt == nil)
        threads.reconcileOrphans(in: fixture.mainBranch)
        #expect(dropped.stopReason == LocalStopReason.orphaned.rawValue && dropped.finishedAt != nil)
    }
}

@Suite("Alignment with the demo transport")
struct AlignmentDemoTests {
    @Test("The demo answers an alignment: steps paired by number, the last pair diverging")
    func demo() async throws {
        let fixture = PreviewFixtures.make(services: .demo, demoPause: .zero)
        let pair = ComparedPair.oriented(fixture.attemptA.stableID, fixture.attemptB.stableID)
        try fixture.state.threads.align(pair, aligner: fixture.slotC.stableID, problem: fixture.problem,
                                        branch: fixture.mainBranch, effort: .standard)
        try await waitUntil(timeout: .seconds(10)) { fixture.state.threads.live.isEmpty }
        let state = ComparisonState.read(fixture.attemptA, fixture.attemptB, in: fixture.problem,
                                         people: fixture.state.problems.personIDs())
        #expect(state.summary.equivalent == 4 && state.summary.diverge == 1 && state.summary.onlyOne == 1)
        #expect(fixture.alignment.modelSummary.contains("demonstration"))
    }
}

@Suite("Questions about attempts: repair and row-to-referee")
struct AttemptQuestionTests {
    private let fixture = PreviewFixtures.make()
    private let provider = ScriptedProvider()
    private let threads: ThreadManager

    init() {
        threads = ThreadManager(context: fixture.state.container.mainContext, saves: fixture.state.saves,
                                problems: fixture.state.problems, credentials: CredentialManager(store: InMemorySecretStore()),
                                registry: ProviderRegistry([provider]))
    }

    private var context: ModelContext { fixture.state.container.mainContext }
    private var attempts: [UUID] { [fixture.messageA.stableID, fixture.messageB.stableID] }

    private func ask(_ slot: ModelSlot, _ text: String = "Repair step 5: $q = p + 1$ happens at $(p, q) = (2, 3)$.") throws -> Message {
        let id = try threads.ask(text, slot: slot.stableID, about: attempts, problem: fixture.problem,
                                 branch: fixture.mainBranch, effort: .standard)
        return try #require(fixture.mainBranch.sortedMessages.first { $0.stableID == id })
    }

    @Test("A repair request goes to the step's author as an ordinary reply, linked to both attempts; no step changes")
    func repair() async throws {
        let revisions = try context.fetchCount(FetchDescriptor<StepRevision>())
        let reply = try ask(fixture.slotB)
        let prompt = try #require(fixture.mainBranch.sortedMessages.first { $0.stableID == reply.derivedFromIDs.first })
        #expect(prompt.kind == .prompt && prompt.derivedFromIDs == attempts && prompt.author == .human(fixture.you.personID))
        #expect(reply.kind == .reply && reply.author == .model(fixture.slotB.slotID))
        #expect(reply.request?.promptVersion == "prover@2" && provider.requests.first?.format == nil)
        provider.reply(to: 0, "Here is a repaired step 5.")
        try await waitUntil { threads.live.isEmpty }
        #expect(try context.fetchCount(FetchDescriptor<StepRevision>()) == revisions, "only a person revises a step")
    }

    @Test("Invariant 1: a referee's answer about one row is prose, never a verdict on the attempts")
    func refereeRow() async throws {
        let verdicts = try context.fetchCount(FetchDescriptor<RefereeVerdict>())
        let graph = fixture.state.graph.state(for: fixture.problem)
        let reply = try ask(fixture.slotC, "Which of the two steps 5 is right?")
        #expect(reply.kind == .refereeReply && reply.kind.authoringRole == .referee)
        #expect(reply.request?.promptVersion == "referee-reply@2" && provider.requests.first?.format == nil)
        provider.reply(to: 0, #"Attempt 1's step holds; Attempt 2's fails at $(p, q) = (2, 3)$."#)
        try await waitUntil { threads.live.isEmpty }
        #expect(try context.fetchCount(FetchDescriptor<RefereeVerdict>()) == verdicts)
        #expect(fixture.state.graph.state(for: fixture.problem) == graph)
    }

    @Test("Invariant 4: the question and its answer derive from the attempts, so they are withheld wherever the attempts are")
    func excludedFromLaterAttempts() throws {
        let reply = try ask(fixture.slotC)
        let snapshot = ProblemSnapshot.make(problem: fixture.problem, branch: fixture.mainBranch,
                                            notation: fixture.state.problems.notation(for: fixture.problem),
                                            people: [fixture.you, fixture.mk], liveMessageIDs: [])
        let fanOut = try #require(snapshot.fanOut(fixture.fanOut.stableID))
        let excluded = ContextBuilder.independentExclusions(fanOut, recipient: fixture.slotA.slotID, in: snapshot)
        #expect(excluded.contains(reply.stableID) && excluded.contains(reply.derivedFromIDs[0]))
    }

    @Test("Refusals write nothing: an empty question, a disallowed provider, a busy branch")
    func refusals() throws {
        let messages = fixture.mainBranch.sortedMessages.count
        #expect(throws: SendBlocker.emptyMessage) { try ask(fixture.slotB, "  ") }
        fixture.state.problems.setProvider(ProviderID.anthropic, allowed: false, for: fixture.problem)
        #expect(throws: SendBlocker.providerNotAllowed(providerID: ProviderID.anthropic, providerName: "Anthropic")) {
            try ask(fixture.slotB)
        }
        fixture.state.problems.setProvider(ProviderID.anthropic, allowed: true, for: fixture.problem)
        try threads.align(ComparedPair.oriented(fixture.attemptA.stableID, fixture.attemptB.stableID),
                          aligner: fixture.slotC.stableID, problem: fixture.problem, branch: fixture.mainBranch,
                          effort: .standard)
        #expect(throws: SendBlocker.busy) { try ask(fixture.slotB) }
        #expect(fixture.mainBranch.sortedMessages.count == messages)
    }
}
