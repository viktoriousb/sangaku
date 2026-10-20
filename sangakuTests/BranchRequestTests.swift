import Foundation
import SwiftData
import Testing
@testable import sangaku

/// Requests on branches, driven by a scripted provider.
@Suite("Branches: requests")
struct BranchRequestTests {
    private let fixture = PreviewFixtures.make()
    private let provider = ScriptedProvider()
    private let threads: ThreadManager

    init() {
        threads = ThreadManager(context: fixture.state.container.mainContext, saves: fixture.state.saves,
                                problems: fixture.state.problems, credentials: CredentialManager(store: InMemorySecretStore()),
                                registry: ProviderRegistry([provider]))
    }

    private var context: ModelContext { fixture.state.container.mainContext }

    @Test("A dead end or parked branch sends nothing: no send, question or referee; an alignment may still compare")
    func closedBranches() throws {
        let messages = try context.fetchCount(FetchDescriptor<Message>())
        for branch in [fixture.classEquation, fixture.parked] {
            let draft = threads.draft(for: branch.stableID)
            draft.text = "Try again."
            let refusal = SendBlocker.context(.branchClosed(branch.state))
            #expect(throws: refusal) { try threads.send(problem: fixture.problem, branch: branch, draft: draft) }
            #expect(draft.text == "Try again.", "the draft is kept for when the branch is reopened")
            #expect(threads.plan(problem: fixture.problem, branch: branch, draft: draft).blocker == refusal)
            #expect(throws: refusal) {
                try threads.ask("Why?", slot: fixture.slotA.stableID, about: [], problem: fixture.problem, branch: branch,
                                effort: .standard)
            }
        }
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == messages)
        #expect(provider.requests.isEmpty)
        #expect(SendBlocker.context(.branchClosed(.parked)).message == "This branch is parked. Reopen it to continue.")
        // Reopened, it sends again.
        try fixture.state.branches.reopen(fixture.classEquation)
        let draft = threads.draft(for: fixture.classEquation.stableID)
        try threads.send(problem: fixture.problem, branch: fixture.classEquation, draft: draft)
        #expect(provider.requests.count == 1)
    }

    @Test("Invariant 4: a referee on a fork made inside the fan-out is refused, writing nothing")
    func refereeOnFork() throws {
        let messages = try context.fetchCount(FetchDescriptor<Message>())
        #expect(throws: SendBlocker.context(.fanOutNotOnBranch(fixture.fanOut.stableID))) {
            try threads.referee(fixture.fanOut, with: fixture.slotC, problem: fixture.problem, branch: fixture.fork,
                                effort: .standard)
        }
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == messages && provider.requests.isEmpty)
    }

    @Test("A fork's new messages come after everything it shows, inherited ones included, whatever the clock says")
    func timeFloors() throws {
        let early = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let threads = ThreadManager(context: context, saves: fixture.state.saves, problems: fixture.state.problems,
                                    credentials: CredentialManager(store: InMemorySecretStore()),
                                    registry: ProviderRegistry([provider]), now: { early })
        let fork = try fixture.state.branches.fork(from: fixture.refereeMessage.stableID, named: "Fresh fork")
        let draft = threads.draft(for: fork.stableID)
        draft.text = "Continue from the referee's verdict."
        try threads.send(problem: fixture.problem, branch: fork, draft: draft)
        let inherited = try #require(fork.visibleHistory.inherited.map(\.createdAt).max())
        #expect(fork.sortedMessages.allSatisfy { $0.createdAt > inherited })
        let sent = try #require(provider.requests.first)
        #expect(sent.turns.last?.blocks.joined().contains("Continue from the referee") == true)
    }

    @Test("Rule 4: a person's revision is stamped after every message in the problem, a fork's referee request included")
    func reviewFloor() throws {
        let early = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let reviews = ReviewManager(context: context, saves: fixture.state.saves, problems: fixture.state.problems,
                                    now: { early })
        let request = Message(author: .model(fixture.slotC.slotID), bodyLaTeX: "A referee pass on the fork.", kind: .referee)
        request.createdAt = PreviewFixtures.day(13, 0)
        fixture.fork.messages = (fixture.fork.messages ?? []) + [request]
        let step = fixture.attemptA.sortedSteps[0]
        try reviews.revise(step.stableID, from: try #require(step.latestRevision?.stableID), text: "Revised.",
                           establishes: step.establishes)
        #expect(try #require(step.latestRevision?.createdAt) > request.createdAt)
    }

    /// Whether a refusal carries the context error, for the request as a whole or for one recipient of it.
    private func carries(_ blocker: SendBlocker?, _ error: ContextError) -> Bool {
        switch blocker {
        case .context(let refused)?: refused == error
        case .recipient(_, let refused)?: refused == error
        default: false
        }
    }

    @Test("Forking from A while B is still being written, then sending: the fork never sees B; B's branch never sees the fork")
    func forkWhileSiblingStreams() throws {
        let activity = TestActivity()
        activity.liveMessageIDs = [fixture.messageB.stableID]
        let manager = fixture.branchManager(activity: activity)
        #expect(throws: BranchError.messageStillRunning) {
            try manager.fork(from: fixture.messageB.stableID, named: "Too soon")
        }
        let fork = try manager.fork(from: fixture.messageA.stableID, named: "From A")
        let draft = threads.draft(for: fork.stableID)
        draft.text = "Tighten step 5."
        try threads.send(problem: fixture.problem, branch: fork, draft: draft)
        let sent = try #require(provider.requests.last).turns.flatMap(\.blocks).joined(separator: "\n")
        let stepOfB = try #require(fixture.attemptB.sortedSteps.last?.textLaTeX)
        #expect(!sent.contains(stepOfB) && sent.contains("Tighten step 5."))
        let parent = fixture.mainBranch.visibleHistory.all
        #expect(parent.contains { $0 === fixture.messageB })
        #expect(!parent.contains { $0.branch === fork }, "the parent never sees the fork's messages")
    }

    @Test("A referee on a fork that shows every attempt runs there; a complete verdict adopts nothing")
    func refereeOnInheritedFanOut() async throws {
        let fork = try fixture.state.branches.fork(from: fixture.messageB.stableID, named: "Both attempts")
        let before = (fixture.problem.adoptedAttemptID, fixture.problem.mainBranchID,
                      Set((fixture.theorem.sourceSteps ?? []).map(\.stableID)))
        try threads.referee(fixture.fanOut, with: fixture.slotC, problem: fixture.problem, branch: fork, effort: .standard)
        let text = try #require(provider.requests.last).turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(text.contains("[Attempt by Model A, to judge]") && text.contains("[Attempt by Model B, to judge]"))
        provider.reply(to: provider.requests.count - 1, DemoOutput.referee(summary: "Both hold.", verdicts: [
            ("A", .complete, [], "Fine."), ("B", .complete, [], "Fine."),
        ]))
        try await waitUntil { threads.live.isEmpty }
        #expect(fork.sortedMessages.last?.kind == .referee, "the referee's message is on the fork")
        #expect(fixture.problem.adoptedAttemptID == before.0 && fixture.problem.mainBranchID == before.1)
        #expect(Set((fixture.theorem.sourceSteps ?? []).map(\.stableID)) == before.2, "a verdict never adopts")
    }

    @Test("Invariant 5: a fork whose history cannot be read sends nothing, keeps the draft and says why")
    func unreadableHistory() throws {
        let fork = fixture.fork
        fork.forkedFrom = nil
        let draft = threads.draft(for: fork.stableID)
        draft.text = "Go on."
        let messages = try context.fetchCount(FetchDescriptor<Message>())
        let fault = ContextError.historyUnreadable(.forkPointMissing)
        let refused = #expect(throws: SendBlocker.self) {
            try threads.send(problem: fixture.problem, branch: fork, draft: draft)
        }
        #expect(carries(refused, fault), "\(String(describing: refused))")
        #expect(carries(threads.plan(problem: fixture.problem, branch: fork, draft: draft).blocker, fault))
        #expect(draft.text == "Go on." && provider.requests.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == messages)
        #expect(fault.message.hasSuffix("Nothing was sent."))
    }

    @Test("Invariant 15 on a fork: a provider the problem does not allow is refused there too, writing nothing")
    func forkPolicy() throws {
        fixture.state.problems.setProvider(ProviderID.anthropic, allowed: false, for: fixture.problem)
        let draft = threads.draft(for: fixture.fork.stableID)
        draft.text = "Go on."
        let messages = try context.fetchCount(FetchDescriptor<Message>())
        let refused = #expect(throws: SendBlocker.self) {
            try threads.send(problem: fixture.problem, branch: fixture.fork, draft: draft)
        }
        let isPolicy = switch refused {
        case .providerNotAllowed?: true
        default: carries(refused, .providerNotAllowed(ProviderID.anthropic))
        }
        #expect(isPolicy, "\(String(describing: refused))")
        #expect(provider.requests.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == messages)
    }

    @Test("Orphan recovery covers the messages a fork shows, inherited ones included")
    func orphans() throws {
        let record = try #require(fixture.messageA.request)
        record.finishedAt = nil
        threads.reconcileOrphans(in: fixture.fork)
        #expect(record.finishedAt != nil && record.stopReason == LocalStopReason.orphaned.rawValue)
    }
}

@Suite("Branches: what every prompt carries")
struct PromptCarriesTests {
    private let fixture = PreviewFixtures.make()

    @Test("Invariant 5: the summary's lines are the lines sent, in order; parked and switched-off dead ends are absent")
    func carries() throws {
        let snapshot = ProblemSnapshot.make(problem: fixture.problem, branch: fixture.mainBranch,
                                            notation: fixture.state.problems.notation(for: fixture.problem),
                                            people: [fixture.you, fixture.mk], liveMessageIDs: [])
        let carries = PromptCarries(snapshot)
        let built = try ContextBuilder().build(ContextInput(
            snapshot: snapshot, providerID: "anthropic", purpose: .reply(slot: fixture.slotA.slotID, fanOut: nil),
            rolePrompt: try #require(PromptLibrary.bundled.prompt(for: .prover)), pending: "Go on.", inputBudget: nil))
        func section(_ kind: ContextSectionKind) -> String { built.stable.first { $0.kind == kind }?.text ?? "" }
        #expect(carries.deadEnds.map(\.line) == section(.deadEnds).split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") })
        #expect(carries.lemmas.map(\.line) == section(.adoptedLemmas).split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") })
        #expect(carries.refuted.map(\.line) == section(.refutedClaims).split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") })
        #expect(carries.deadEnds.map(\.title) == ["Class equation", "Induction on |G|"])
        #expect(!carries.deadEnds.contains { $0.title == fixture.parked.name })
        // The panel shows the very line a dead end is sent as.
        #expect(ContextBuilder.deadEndLine(.init(fixture.classEquation))
                == "- Class equation: Tried: class equation alone. Stalls on |Z(G)|. Don't retry without new input on the center.")
    }
}
