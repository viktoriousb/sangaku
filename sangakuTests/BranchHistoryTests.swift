import Foundation
import SwiftData
import Testing
@testable import sangaku

/// Hand-built fork chains for the pure history rule.
private enum Lines {
    static func line(_ id: UUID, own: [UUID], fork: (point: UUID, owner: UUID)? = nil,
                     wasForked: Bool? = nil) -> BranchHistory.Line {
        BranchHistory.Line(id: id, forkPoint: fork?.point, forkOwner: fork?.owner,
                           wasForked: wasForked ?? (fork != nil), own: own)
    }
}

@Suite("Branches: the history rule")
struct BranchHistoryTests {
    @Test("A fork reads its parent's history up to and including the fork point, then its own; recursively")
    func chain() {
        let main = UUID(), fork = UUID(), grandchild = UUID()
        let m = (0..<4).map { _ in UUID() }, f = (0..<2).map { _ in UUID() }, g = [UUID()]
        let lines = [
            main: Lines.line(main, own: m),
            fork: Lines.line(fork, own: f, fork: (m[1], main)),
            grandchild: Lines.line(grandchild, own: g, fork: (f[0], fork)),
        ]
        #expect(BranchHistory.visible(main, in: lines).all == m)
        let visible = BranchHistory.visible(fork, in: lines)
        #expect(visible.inherited == Array(m[0...1]) && visible.own == f && visible.fault == nil)
        #expect(BranchHistory.visible(grandchild, in: lines).all == [m[0], m[1], f[0], g[0]])
        #expect(visible.through(m[1]) == Array(m[0...1]) && visible.through(UUID()) == nil)
    }

    @Test("A fork from a message its parent only inherited reads that message's owner, never the parent's own")
    func forkFromInherited() {
        let main = UUID(), fork = UUID(), sibling = UUID()
        let m = (0..<3).map { _ in UUID() }, f = [UUID()]
        // Forked at m[0], which the fork only inherits: the new branch's owner is main.
        let lines = [
            main: Lines.line(main, own: m),
            fork: Lines.line(fork, own: f, fork: (m[2], main)),
            sibling: Lines.line(sibling, own: [], fork: (m[0], main)),
        ]
        #expect(BranchHistory.visible(sibling, in: lines).all == [m[0]])
    }

    @Test("Fail closed: a missing fork point or owner, a fork with no point, and a cycle read the own messages only")
    func faults() {
        let main = UUID(), fork = UUID(), a = UUID(), b = UUID()
        let own = [UUID()]
        var lines = [main: Lines.line(main, own: [UUID()]), fork: Lines.line(fork, own: own, fork: (UUID(), main))]
        #expect(BranchHistory.visible(fork, in: lines) == .init(inherited: [], own: own, fault: .forkPointMissing))
        lines[fork] = Lines.line(fork, own: own, fork: (UUID(), UUID()))
        #expect(BranchHistory.visible(fork, in: lines).fault == .forkPointMissing)
        lines[fork] = Lines.line(fork, own: own, wasForked: true)
        #expect(BranchHistory.visible(fork, in: lines).fault == .forkPointMissing, "a fork whose point is gone is no root")
        let x = UUID(), y = UUID()
        let cycle = [a: Lines.line(a, own: [x], fork: (y, b)), b: Lines.line(b, own: [y], fork: (x, a))]
        let read = BranchHistory.visible(a, in: cycle)
        #expect(read.fault == .cycle && read.inherited.isEmpty && read.own == [x])
    }

    @Test("Ties in time are broken by ID, so every reader orders messages the same way")
    func ties() {
        let time = Date(timeIntervalSinceReferenceDate: 1)
        let ids = (0..<5).map { _ in UUID() }
        let sorted = ids.sorted { BranchHistory.precedes((time, $0), (time, $1)) }
        #expect(sorted == ids.sorted { $0.uuidString < $1.uuidString })
    }

    @Test("Against a naive rule over 200 random forests: a fork sees its parent's history through the fork point")
    func property() {
        var random = SeededGenerator(state: 7)
        for _ in 0..<200 {
            var lines: [UUID: BranchHistory.Line] = [:]
            var order: [UUID] = []
            for _ in 0..<Int.random(in: 1...6, using: &random) {
                let id = UUID()
                let own = (0..<Int.random(in: 0...4, using: &random)).map { _ in UUID() }
                // Fork from a message of an earlier branch, which that branch owns.
                let owners = order.filter { !(lines[$0]?.own.isEmpty ?? true) }
                if let owner = owners.randomElement(using: &random), Bool.random(using: &random),
                   let point = lines[owner]?.own.randomElement(using: &random) {
                    lines[id] = Lines.line(id, own: own, fork: (point, owner))
                } else {
                    lines[id] = Lines.line(id, own: own)
                }
                order.append(id)
            }
            func naive(_ id: UUID) -> [UUID] {
                guard let line = lines[id] else { return [] }
                guard let point = line.forkPoint, let owner = line.forkOwner else { return line.own }
                let parent = naive(owner)
                return Array(parent[...parent.firstIndex(of: point)!]) + line.own
            }
            for id in order {
                let visible = BranchHistory.visible(id, in: lines)
                #expect(visible.fault == nil && visible.all == naive(id))
                #expect(Set(visible.all).count == visible.all.count, "no message twice")
            }
        }
    }
}

@Suite("Branches: what is shown is what is sent")
struct BranchAgreementTests {
    private let fixture = PreviewFixtures.make()

    private func snapshot(_ branch: Branch, live: Set<UUID> = []) -> ProblemSnapshot {
        ProblemSnapshot.make(problem: fixture.problem, branch: branch,
                             notation: fixture.state.problems.notation(for: fixture.problem),
                             people: [fixture.you, fixture.mk], liveMessageIDs: live)
    }

    @Test("Decision 1: for every branch, the thread, Review's attempts and the model's conversation are one history")
    func agreement() {
        for branch in fixture.problem.sortedBranches {
            let history = branch.visibleHistory
            let sent = snapshot(branch).messages.map(\.id)
            #expect(history.ids == sent, "\(branch.name)")
            let shown = ThreadItem.make(history.all).flatMap { item -> [UUID] in
                switch item {
                case .message(let message): [message.stableID]
                case .fanOut(let prompt, _, let attempts): [prompt.stableID] + attempts.map(\.stableID)
                }
            }
            #expect(Set(shown).isSubset(of: Set(sent)), "\(branch.name): the thread shows nothing the model is not sent")
            let attempts = AttemptOption.make(messages: history.all, live: []).map(\.id)
            #expect(Set(attempts).isSubset(of: Set(history.all.compactMap(\.proofAttempt?.stableID))))
        }
    }

    @Test("A fork made inside the fan-out: the prompt and A's attempt, never B's, the referee's or anything later")
    func forkInsideFanOut() throws {
        let fork = fixture.fork
        let history = fork.visibleHistory
        #expect(history.inherited.map(\.stableID) == [fixture.fanOutPrompt.stableID, fixture.messageA.stableID])
        #expect(history.own.map(\.stableID).contains(fixture.forkReply.stableID))
        let items = ThreadItem.make(history.all)
        guard case .fanOut(_, _, let attempts) = try #require(items.first) else {
            Issue.record("the fan-out is one item")
            return
        }
        #expect(attempts.map(\.stableID) == [fixture.messageA.stableID], "B's attempt is not on this branch")
        // Invariant 4: a referee here would judge only some attempts, so it is refused.
        let rolePrompt = try #require(PromptLibrary.bundled.prompt(for: .referee, structured: true))
        let input = ContextInput(snapshot: snapshot(fork), providerID: "anthropic",
                                 purpose: .referee(slot: fixture.slotC.slotID, fanOut: fixture.fanOut.stableID),
                                 rolePrompt: rolePrompt, pending: "Judge.", inputBudget: nil)
        #expect(throws: ContextError.fanOutNotOnBranch(fixture.fanOut.stableID)) { try ContextBuilder().build(input) }
    }

    @Test("Invariant 4 across a fork: the fork's own request never carries B's attempt; the parent's still does")
    func independence() throws {
        let prompt = try #require(PromptLibrary.bundled.prompt(for: .prover))
        func transcript(_ branch: Branch) throws -> String {
            try ContextBuilder().build(ContextInput(
                snapshot: snapshot(branch), providerID: "anthropic", purpose: .reply(slot: fixture.slotA.slotID, fanOut: nil),
                rolePrompt: prompt, pending: "Go on.", inputBudget: nil)).transcript
        }
        let bText = try #require(fixture.attemptB.sortedSteps.last?.textLaTeX)
        #expect(try !transcript(fixture.fork).contains(bText))
        #expect(try transcript(fixture.mainBranch).contains(bText))
        #expect(try transcript(fixture.fork).contains(try #require(fixture.attemptA.sortedSteps.first?.textLaTeX)))
    }

    @Test("Invariant 5: a short window leaves out the inherited messages first, and records each as before the fork")
    func dropsInheritedFirst() throws {
        let prompt = try #require(PromptLibrary.bundled.prompt(for: .prover))
        let input = { (budget: Int?) in
            ContextInput(snapshot: snapshot(fixture.fork), providerID: "anthropic",
                         purpose: .reply(slot: fixture.slotA.slotID, fanOut: nil), rolePrompt: prompt,
                         pending: "Go on.", inputBudget: budget)
        }
        let full = try ContextBuilder().build(input(nil))
        let tight = try ContextBuilder().build(input(Int(Double(full.totalTokens) * 0.9)))
        let first = try #require(tight.dropped.first)
        #expect(first.kind == "Message" && first.title.hasSuffix("(before the fork)"))
        #expect(tight.includedMessageIDs.contains(fixture.forkReply.stableID), "the fork's own latest exchange stays")
        if case .dropped = tight.fit {} else { Issue.record("the fit says what was dropped") }
    }

    @Test("A closed branch sends nothing and says why; an unreadable history sends nothing either")
    func closed() throws {
        let prompt = try #require(PromptLibrary.bundled.prompt(for: .prover))
        func build(_ snapshot: ProblemSnapshot) throws(ContextError) -> BuiltContext {
            try ContextBuilder().build(ContextInput(snapshot: snapshot, providerID: "anthropic",
                                                   purpose: .reply(slot: fixture.slotA.slotID, fanOut: nil),
                                                   rolePrompt: prompt, pending: "Go on.", inputBudget: nil))
        }
        #expect(throws: ContextError.branchClosed(.deadEnd)) { try build(snapshot(fixture.classEquation)) }
        #expect(throws: ContextError.branchClosed(.parked)) { try build(snapshot(fixture.parked)) }
        var faulty = snapshot(fixture.fork)
        faulty.historyFault = .forkPointMissing
        #expect(throws: ContextError.historyUnreadable(.forkPointMissing)) { try build(faulty) }
        #expect(ContextError.branchClosed(.deadEnd).message == "This branch is a dead end. Reopen it to continue.")
    }

    @Test("Losing the fork point fails closed: the fork keeps its own messages and is refused, never silently short")
    func lostForkPoint() {
        fixture.fork.forkedFrom = nil
        let history = fixture.fork.visibleHistory
        #expect(history.fault == .forkPointMissing && history.inherited.isEmpty && !history.own.isEmpty)
        #expect(snapshot(fixture.fork).historyFault == .forkPointMissing)
    }
}
