import Foundation
import SwiftData
import Testing
@testable import sangaku

@Suite("Branch manager")
struct BranchManagerTests {
    private let fixture = PreviewFixtures.make()
    private let activity = TestActivity()
    private let frozen = Date(timeIntervalSinceReferenceDate: 900_000_000)
    private let branches: BranchManager

    init() {
        let frozen = frozen
        branches = fixture.branchManager(activity: activity, now: { frozen })
    }

    private var context: ModelContext { fixture.state.container.mainContext }
    private var contextRevision: Int { fixture.state.problems.contextRevisions[fixture.problem.stableID, default: 0] }

    private func snapshot(_ branch: Branch) -> ProblemSnapshot {
        ProblemSnapshot.make(problem: fixture.problem, branch: branch,
                             notation: fixture.state.problems.notation(for: fixture.problem),
                             people: [fixture.you, fixture.mk], liveMessageIDs: [])
    }

    /// Everything a refusal must leave as it was.
    private func store() throws -> [String] {
        let problem = fixture.problem
        return [
            "\(try context.fetchCount(FetchDescriptor<Branch>()))", "\(try context.fetchCount(FetchDescriptor<Message>()))",
            "\(problem.mainBranchID?.uuidString ?? "")", "\(problem.adoptedAttemptID?.uuidString ?? "")",
            "\((fixture.theorem.sourceSteps ?? []).map(\.stableID.uuidString).sorted())",
        ] + problem.sortedBranches.map { "\($0.name) \($0.stateRaw) \($0.includeReasonInContext) \($0.reason ?? "")" }
    }

    // MARK: Forking

    @Test("A fork copies nothing: it reads its parent's history through the fork point, and is made last")
    func fork() throws {
        let messages = try context.fetchCount(FetchDescriptor<Message>())
        let branch = try branches.fork(from: fixture.refereeMessage.stableID, named: "  Spell out step 6 \n ")
        #expect(branch.name == "Spell out step 6" && branch.state == .live)
        #expect(branch.parent === fixture.mainBranch && branch.forkedFrom === fixture.refereeMessage)
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == messages, "nothing is copied")
        let history = branch.visibleHistory
        #expect(history.inherited.last === fixture.refereeMessage && history.own.isEmpty)
        #expect(history.inherited.allSatisfy { $0.branch === fixture.mainBranch }, "the same messages, by identity")
        #expect(fixture.problem.sortedBranches.last === branch && fixture.problem.sortedBranches.first === fixture.mainBranch)
        // A fork from a message the fork only inherits belongs to that message's branch.
        let sibling = try branches.fork(from: fixture.messageA.stableID, named: "Another")
        #expect(sibling.parent === fixture.mainBranch)
    }

    @Test("Forking is refused for an empty or taken name, and while the message or one before it is being written")
    func forkRefusals() throws {
        let before = try store()
        #expect(throws: BranchError.emptyName) { try branches.fork(from: fixture.reply.stableID, named: " ") }
        #expect(throws: BranchError.duplicateName("class equation")) {
            try branches.fork(from: fixture.reply.stableID, named: "class equation")
        }
        #expect(throws: BranchError.noSuchMessage) { try branches.fork(from: UUID(), named: "New") }
        activity.liveMessageIDs = [fixture.messageB.stableID]
        #expect(throws: BranchError.messageStillRunning) { try branches.fork(from: fixture.reply.stableID, named: "Late") }
        #expect(try store() == before)
        _ = try branches.fork(from: fixture.messageA.stableID, named: "Early")
    }

    // MARK: Retiring

    @Test("Invariant 5: a dead end's reason goes into every prompt by default; parked and reopened branches never")
    func deadEnd() throws {
        let fork = fixture.fork
        var draft = ReasonDraft(reason: "The parity argument needs $p$ odd.", reasonForModels: "Tried: parity alone.")
        draft.start(.models, from: "Tried: parity alone.", messageID: fixture.forkReply.stableID)
        let revision = contextRevision
        try branches.markDeadEnd(fork, draft)
        #expect(fork.state == .deadEnd && fork.includeReasonInContext && contextRevision == revision + 1)
        #expect(fork.modelTextFromMessageID == fixture.forkReply.stableID && fork.modelTextByID == fixture.you.stableID)
        #expect(fork.reasonByID == fixture.you.stableID && fork.stateChangedAt == frozen)
        let sent = snapshot(fixture.mainBranch).deadEnds.map(ContextBuilder.deadEndLine)
        #expect(sent.contains("- Parity argument: Tried: parity alone."))

        try branches.reopen(fork)
        #expect(fork.state == .live && fork.reason == "The parity argument needs $p$ odd.", "reasons are kept")
        #expect(!snapshot(fixture.mainBranch).deadEnds.contains { $0.id == fork.stableID })
        try branches.park(fork, ReasonDraft(reason: "Later."))
        #expect(!snapshot(fixture.mainBranch).deadEnds.contains { $0.id == fork.stableID }, "parked is never sent")
    }

    @Test("The rules for retiring: never the main line, not while running, and no dead end in context without a reason")
    func retiringRefusals() throws {
        let before = try store()
        #expect(throws: BranchError.isMainLine) { try branches.markDeadEnd(fixture.mainBranch, ReasonDraft(reason: "x")) }
        #expect(throws: BranchError.isMainLine) { try branches.park(fixture.mainBranch, ReasonDraft()) }
        activity.streamingBranchIDs = [fixture.fork.stableID]
        #expect(throws: BranchError.branchBusy) { try branches.markDeadEnd(fixture.fork, ReasonDraft(reason: "x")) }
        activity.streamingBranchIDs = []
        #expect(throws: BranchError.reasonRequired) { try branches.markDeadEnd(fixture.fork, ReasonDraft()) }
        var elsewhere = ReasonDraft(reason: "x")
        elsewhere.start(.people, from: "x", messageID: fixture.deadEndReply.stableID)
        #expect(throws: BranchError.messageNotOnBranch) { try branches.markDeadEnd(fixture.fork, elsewhere) }
        #expect(throws: BranchError.notClosed) { try branches.editReasons(of: fixture.fork, ReasonDraft(reason: "x")) }
        #expect(throws: BranchError.notADeadEnd) { try branches.setInContext(true, for: fixture.parked) }
        #expect(try store() == before)
        // With In Context off, a dead end may have no reason: nothing is sent.
        try branches.markDeadEnd(fixture.fork, ReasonDraft(includeInContext: false))
        #expect(!fixture.fork.includeReasonInContext)
        #expect(throws: BranchError.reasonRequired) { try branches.setInContext(true, for: fixture.fork) }
    }

    @Test("Editing reasons stamps only the text that changed, and only with a person")
    func editing() throws {
        let branch = fixture.classEquation
        let models = (branch.modelTextByID, branch.modelTextAt)
        var draft = ReasonDraft(reason: "Rewritten.", reasonForModels: branch.reasonForModels ?? "",
                                includeInContext: true, modelTextFromMessageID: branch.modelTextFromMessageID)
        try branches.editReasons(of: branch, draft)
        #expect(branch.reason == "Rewritten." && branch.reasonAt == frozen && branch.reasonFromMessageID == nil)
        #expect(branch.modelTextByID == models.0 && branch.modelTextAt == models.1, "the text for models did not change")
        draft.includeInContext = false
        try branches.editReasons(of: branch, draft)
        #expect(!branch.includeReasonInContext && !snapshot(fixture.mainBranch).deadEnds.contains { $0.id == branch.stableID })
        let people = fixture.state.problems.personIDs()
        for branch in fixture.problem.sortedBranches {
            for id in [branch.reasonByID, branch.modelTextByID, branch.stateChangedByID].compactMap({ $0 }) {
                #expect(people.contains(id), "only a person writes a reason")
            }
        }
    }

    // MARK: Adopting

    @Test("Invariants 1 and 13: adopting sets the theorem's proof and the main line; its status is earned, never granted")
    func adopt() throws {
        let reviews = try context.fetchCount(FetchDescriptor<Review>())
        let verdicts = try context.fetchCount(FetchDescriptor<RefereeVerdict>())
        let revisions = try context.fetchCount(FetchDescriptor<StepRevision>())
        let holds = fixture.alignment.holdsRaw
        let assessment = try #require(branches.assessment(ofAttempt: fixture.attemptB.stableID))
        #expect(assessment.warnings == [.gap(steps: [5])] && assessment.refusal == nil && assessment.branchIsMain)
        #expect(throws: BranchError.warningsNotAcknowledged) {
            try branches.adopt(attempt: fixture.attemptB.stableID, acknowledging: [])
        }
        try branches.adopt(attempt: fixture.attemptB.stableID, acknowledging: Set(assessment.warnings))
        let sources: Set<UUID> = Set((fixture.theorem.sourceSteps ?? []).map(\.stableID))
        let stepsOfB: Set<UUID> = Set(fixture.attemptB.sortedSteps.map(\.stableID))
        #expect(sources == stepsOfB)
        let problem = fixture.problem
        #expect(problem.adoptedAttemptID == fixture.attemptB.stableID)
        #expect(problem.adoptedAt == frozen)
        #expect(problem.adoptedByID == fixture.you.stableID)
        #expect(problem.mainBranchID == fixture.mainBranch.stableID)
        let theorem = fixture.state.graph.state(for: fixture.problem)[fixture.theorem.stableID]
        #expect(theorem?.derived.own == .sketched, "B has a gap: adopting it checks nothing")
        let theoremID = fixture.theorem.stableID
        let stillA = fixture.attemptA.sortedSteps.contains { step in
            (step.statements ?? []).contains { $0.stableID == theoremID }
        }
        #expect(!stillA, "A's steps are no longer the theorem's")
        #expect(try context.fetchCount(FetchDescriptor<Review>()) == reviews)
        #expect(try context.fetchCount(FetchDescriptor<RefereeVerdict>()) == verdicts)
        #expect(try context.fetchCount(FetchDescriptor<StepRevision>()) == revisions)
        #expect(fixture.alignment.holdsRaw == holds, "adopting records no blind verdict")
    }

    @Test("Adopting moves the main line to the branch the attempt was written on, and refuses on a closed one")
    func adoptElsewhere() throws {
        let attempt = fixture.inductionAttempt.stableID
        let before = try store()
        #expect(branches.assessment(ofAttempt: attempt)?.refusal == .branchClosed(.deadEnd))
        #expect(throws: BranchError.branchClosed(.deadEnd)) {
            try branches.adopt(attempt: attempt, acknowledging: [.unrefereed])
        }
        #expect(try store() == before)
        try branches.reopen(fixture.induction)
        let assessment = try #require(branches.assessment(ofAttempt: attempt))
        #expect(!assessment.branchIsMain && assessment.warnings == [.unrefereed])
        try branches.adopt(attempt: attempt, acknowledging: Set(assessment.warnings))
        #expect(fixture.problem.mainBranchID == fixture.induction.stableID)
        #expect(throws: BranchError.alreadyAdopted) { try branches.adopt(attempt: attempt, acknowledging: [.unrefereed]) }
        #expect(throws: BranchError.isMainLine) { try branches.park(fixture.induction, ReasonDraft()) }
        #expect(throws: BranchError.noSuchAttempt) { try branches.adopt(attempt: UUID(), acknowledging: []) }
    }

    @Test("A, adopted in the example, warns that steps 3 and 5 changed after the referee; still running refuses")
    func assessmentOfA() throws {
        let assessment = try #require(branches.assessment(ofAttempt: fixture.attemptA.stableID))
        #expect(assessment.refusal == .alreadyAdopted)
        #expect(assessment.warnings == [.revisedSinceReferee(steps: [3, 5])])
        #expect(assessment.progress.headline == "4 of 6 steps checked by a person")
        #expect(AdoptionWarning.revisedSinceReferee(steps: [3, 5]).message == "Steps 3 and 5 changed after the referee judged the attempt.")
        activity.liveMessageIDs = [fixture.messageB.stableID]
        #expect(branches.assessment(ofAttempt: fixture.attemptB.stableID)?.refusal == .attemptStillRunning)
    }

    @Test("Adoption warnings: stopped early, a verdict on unknown text, and several at once, in a fixed order")
    func warnings() throws {
        let referee = UUID()
        func standing(_ index: Int, _ model: ModelCheck) -> StepStanding {
            StepStanding(id: UUID(), index: index, model: model)
        }
        #expect(AdoptionWarning.warnings(standings: [standing(1, .complete(referee: referee))], partial: true) == [.partial])
        #expect(AdoptionWarning.warnings(standings: [standing(1, .complete(referee: referee)),
                                                     standing(2, .unknownBasis(referee: referee))], partial: false)
                == [.unrefereed])
        #expect(AdoptionWarning.warnings(standings: [], partial: false) == [.unrefereed])
        let mixed = AdoptionWarning.warnings(standings: [
            standing(3, .revisedSince(referee: referee)), standing(1, .gapListed(referee: referee)),
            standing(2, .noVerdict), standing(4, .attemptHasGap(referee: referee)),
        ], partial: true)
        #expect(mixed == [.partial, .unrefereed, .gap(steps: [1]), .revisedSinceReferee(steps: [3])])
        #expect(AdoptionWarning.gap(steps: []).message == "A referee found a gap in this attempt.")
        #expect(AdoptionWarning.revisedSinceReferee(steps: [2]).message == "Step 2 changed after the referee judged the attempt.")

        // Through the manager: B stopped early warns of that too, and every warning must be acknowledged.
        fixture.messageB.interrupted = true
        let assessment = try #require(branches.assessment(ofAttempt: fixture.attemptB.stableID))
        #expect(assessment.warnings == [.partial, .gap(steps: [5])])
        #expect(throws: BranchError.warningsNotAcknowledged) {
            try branches.adopt(attempt: fixture.attemptB.stableID, acknowledging: [.gap(steps: [5])])
        }
        try branches.adopt(attempt: fixture.attemptB.stableID, acknowledging: Set(assessment.warnings))
        #expect(fixture.problem.adoptedAttemptID == fixture.attemptB.stableID)
    }

    // MARK: Cherry-picking and deleting

    @Test("Cherry-pick opens Promote on the branch's own finished attempts; the lemma refers to the original steps")
    func cherryPick() throws {
        let target = try branches.cherryPickTarget(of: fixture.induction)
        #expect(target.attemptIDs == [fixture.inductionAttempt.stableID])
        #expect(throws: BranchError.nothingToCherryPick) { try branches.cherryPickTarget(of: fixture.classEquation) }
        let salvaged = PreviewFixtures.makeSalvaged()
        let lemma = try #require(salvaged.problem.statements?.first { $0.label == "Lem 8" })
        #expect(lemma.sourceSteps?.first === salvaged.inductionAttempt.sortedSteps[1])
        let snapshot = ProblemSnapshot.make(problem: salvaged.problem, branch: salvaged.mainBranch,
                                            notation: salvaged.state.problems.notation(for: salvaged.problem),
                                            people: [salvaged.you, salvaged.mk], liveMessageIDs: [])
        #expect(snapshot.adoptedLemmas.contains { $0.label == "Lem 8" }, "a salvaged lemma goes into every prompt")
    }

    @Test("Decision 4: no branch or message is ever deleted; only deleting a problem removes them")
    func noDeletion() throws {
        let counts = { [context] in
            (try context.fetchCount(FetchDescriptor<Branch>()), try context.fetchCount(FetchDescriptor<Message>()),
             try context.fetchCount(FetchDescriptor<Statement>()))
        }
        let before = try counts()
        let fork = try branches.fork(from: fixture.reply.stableID, named: "Temporary")
        try branches.markDeadEnd(fork, ReasonDraft(reason: "No."))
        try branches.reopen(fork)
        try branches.park(fork, ReasonDraft())
        try branches.markDeadEnd(fixture.fork, ReasonDraft(reason: "No."))
        let after = try counts()
        #expect(after.0 == before.0 + 1 && after.1 == before.1 && after.2 == before.2)
        // The source: every deletion in the app deletes a problem, a notation entry, a review or a statement, and
        // nothing is named for deleting a branch or a message. A scan that reads nothing fails.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "sangaku")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var deletions: [String] = [], named: [String] = [], scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let lower = line.lowercased(), place = url.lastPathComponent + ": " + line.trimmingCharacters(in: .whitespaces)
                if lower.contains("context.delete(") { deletions.append(place) }
                if ["deletebranch", "deletemessage", "branches.delete(", "messages.delete(", "branch.delete(",
                    "message.delete("].contains(where: lower.contains) { named.append(place) }
            }
        }
        #expect(scanned > 100, "the scan read the app's sources")
        let allowed = ["ProblemManager.swift", "ReviewManager.swift", "StatementGraph.swift"]
        #expect(deletions.allSatisfy { line in allowed.contains { line.hasPrefix($0 + ":") } }, "\(deletions)")
        for file in allowed { #expect(deletions.contains { $0.hasPrefix(file + ":") }, "the scan finds \(file)") }
        #expect(named.isEmpty, "\(named)")
    }
}

@Suite("Branch intents")
struct BranchIntentTests {
    private let fixture = PreviewFixtures.make()

    @Test("Each intent opens its sheet or acts at once, finding its branch through the manager when it runs")
    func effects() throws {
        let manager = fixture.branchManager(activity: TestActivity())
        let window = WindowState()
        window.select(problem: fixture.problem)
        func perform(_ intent: BranchIntent) { BranchIntentHandler.perform(intent, window: window, branches: manager) }

        perform(.fork(messageID: fixture.reply.stableID))
        #expect(window.branchSheet == .newBranch(fromMessage: fixture.reply.stableID))
        perform(.newBranch(branchID: fixture.fork.stableID))
        #expect(window.branchSheet == .newBranch(fromMessage: try #require(fixture.fork.visibleHistory.all.last).stableID))
        perform(.markDeadEnd(branchID: fixture.fork.stableID))
        #expect(window.branchSheet == .reasons(branchID: fixture.fork.stableID, mode: .deadEnd))
        perform(.park(branchID: fixture.fork.stableID))
        #expect(window.branchSheet == .reasons(branchID: fixture.fork.stableID, mode: .park))
        perform(.editReasons(branchID: fixture.parked.stableID))
        #expect(window.branchSheet == .reasons(branchID: fixture.parked.stableID, mode: .edit))
        perform(.adopt(attemptID: fixture.attemptB.stableID))
        #expect(window.branchSheet == .adopt(attemptID: fixture.attemptB.stableID))
        perform(.cherryPick(branchID: fixture.induction.stableID))
        #expect(window.branchSheet == .cherryPick(PromotionTarget(attemptIDs: [fixture.inductionAttempt.stableID])))
        window.branchSheet = nil
        perform(.cherryPick(branchID: fixture.classEquation.stableID))
        #expect(window.branchSheet == nil, "nothing to cherry-pick: refused, and said")

        perform(.reopen(branchID: fixture.parked.stableID))
        #expect(fixture.parked.state == .live)
        window.activeView = .review
        perform(.show(branchID: fixture.fork.stableID))
        #expect(window.selectedBranchID == fixture.fork.stableID && window.activeView == .review)
        perform(.openMessages(branchID: fixture.induction.stableID))
        #expect(window.selectedBranchID == fixture.induction.stableID && window.activeView == .thread)
        window.showsDeadEnds = false
        perform(.showInBranches(fixture.classEquation.stableID))
        #expect(window.showsDeadEnds && window.activeView == .branches)
        #expect(window.branchesSelection == fixture.classEquation.stableID)
        window.inspectorPresented = false
        perform(.revealStatement(fixture.lemmas[0].stableID))
        #expect(window.selectedNodeID == fixture.lemmas[0].stableID && window.inspectorPresented)
        perform(.editProblem)
        #expect(window.isEditingProblem)

        // Gone by the time it runs, or no manager: nothing happens.
        window.branchSheet = nil
        perform(.newBranch(branchID: UUID()))
        perform(.reopen(branchID: UUID()))
        BranchIntentHandler.perform(.markDeadEnd(branchID: fixture.fork.stableID), window: window, branches: nil)
        #expect(window.branchSheet == nil)
    }
}
