import Foundation
import Observation
import SwiftData
import Testing
@testable import sangaku

/// Counts `markDirty` calls: each one starts a save task, which calls the injected sleep.
private final class DirtyCounter {
    var count = 0
}

/// Set from an observation callback, which runs synchronously on the main thread during the change.
nonisolated private final class Fired: @unchecked Sendable {
    var value = false
}

@Suite("Review manager")
struct ReviewManagerTests {
    private let fixture = PreviewFixtures.make()
    private let dirty = DirtyCounter()
    /// Earlier than everything in the example, so every write must be floored above what is already recorded.
    private let frozen = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private let reviews: ReviewManager

    init() {
        let counter = dirty
        let saves = SaveScheduler(context: fixture.state.container.mainContext, sleep: { _ in
            counter.count += 1
            throw CancellationError()
        })
        let frozen = frozen
        reviews = ReviewManager(context: fixture.state.container.mainContext, saves: saves,
                                problems: fixture.state.problems, now: { frozen })
    }

    private var steps: [Step] { fixture.attemptA.sortedSteps }
    private var people: Set<UUID> { fixture.state.problems.personIDs() }
    private var contextRevision: Int { fixture.state.problems.contextRevisions[fixture.problem.stableID, default: 0] }
    private func current(_ step: Step) -> UUID { step.latestRevision!.stableID }
    private func standing(_ step: Step) -> StepStanding { reviews.state(of: fixture.attemptA)[step: step.stableID]!.standing }
    private func displayed(_ statement: Statement) -> StatementStatus? {
        fixture.state.graph.state(for: fixture.problem)[statement.stableID]?.derived.displayed
    }

    /// Lets the save tasks started by `markDirty` run, then gives how many there were since the last call.
    private func dirtyCount() async -> Int {
        for _ in 0..<10 { await Task.yield() }
        defer { dirty.count = 0 }
        return dirty.count
    }

    private var openQuestion: Review { steps[4].reviews!.first { $0.verdict == .unclear }! }

    @Test("Invariant 1: the reviewer is always the person using the app")
    func reviewerIsMe() throws {
        let outcome = try reviews.mark(.correct, step: steps[5].stableID, revision: current(steps[5]))
        guard case .recorded(let id) = outcome else { Issue.record("not recorded"); return }
        let review = try #require(steps[5].reviews?.first { $0.stableID == id })
        #expect(review.reviewerID == fixture.you.stableID && people.contains(fixture.you.stableID))
        #expect(review.revisionReviewedID == current(steps[5]))
    }

    @Test("Invariant 2: a ✓ lifts the statement; a revision makes the step unchecked again and the statement falls")
    func markThenRevise() throws {
        let lemma4 = fixture.lemmas[3]
        #expect(displayed(lemma4) == .modelChecked)
        try reviews.mark(.correct, step: steps[5].stableID, revision: current(steps[5]))
        #expect(displayed(lemma4) == .humanChecked)
        try reviews.revise(steps[5].stableID, from: current(steps[5]), text: steps[5].textLaTeX + " Hence the claim.",
                           establishes: steps[5].establishes)
        #expect(standing(steps[5]).human == .unchecked)
        #expect(displayed(lemma4) == .sketched, "unchecked, and newer than the referee's verdict (rule 4)")
    }

    @Test("Rule 4: a person's revision after the referee drops the statement until a new pass sees it")
    func rule4AfterRevision() throws {
        let lemma4 = fixture.lemmas[3]
        try reviews.revise(steps[5].stableID, from: current(steps[5]), text: "Reworded.", establishes: steps[5].establishes)
        #expect(standing(steps[5]).model == .revisedSince(referee: fixture.slotC.stableID))
        #expect(displayed(lemma4) == .sketched)
        let verdict = RefereeVerdict(outcome: .complete)
        verdict.requestedAt = steps[5].latestRevision!.createdAt.addingTimeInterval(1)
        verdict.createdAt = verdict.requestedAt!.addingTimeInterval(30)
        fixture.state.container.mainContext.insert(verdict)
        verdict.attempt = fixture.attemptA
        #expect(displayed(lemma4) == .modelChecked)
    }

    @Test("Invariant 7: a revision records me as its author, updates the mirror and keeps the history, in time order")
    func provenance() throws {
        let step = steps[1]
        let before = (step.revisions ?? []).map(\.stableID)
        let verdictTimes = (fixture.attemptA.verdicts ?? []).flatMap { [$0.createdAt, $0.requestedAt!] }
        try reviews.revise(step.stableID, from: current(step), text: "  A tidier step 2.  ", establishes: " q > p ")
        let latest = try #require(step.latestRevision)
        #expect(latest.author == .human(fixture.you.personID))
        #expect(step.textLaTeX == "A tidier step 2." && step.establishes == "q > p")
        #expect(latest.textLaTeX == "A tidier step 2.")
        #expect(Set(before).isSubset(of: Set((step.revisions ?? []).map(\.stableID))))
        #expect(latest.createdAt > frozen, "floored above what is recorded, though the clock is behind")
        let everything = fixture.attemptA.sortedSteps.flatMap { step in
            (step.revisions ?? []).filter { $0 !== latest }.map(\.createdAt) + (step.reviews ?? []).map(\.createdAt)
        } + verdictTimes
        #expect(everything.allSatisfy { $0 < latest.createdAt })
        #expect(standing(step).staleReviews.count == 1, "MK's ✓ stays in the history")
    }

    @Test("Invariant 11: a later ✓ does not close an objection; a dismissal needs a reason and an open objection")
    func dismissals() throws {
        let step5 = steps[4]
        try reviews.mark(.correct, step: step5.stableID, revision: current(step5))
        #expect(standing(step5).human == .objected)
        #expect(throws: ReviewError.reasonRequired) { try reviews.dismiss(openQuestion.stableID, reason: "") }
        #expect(throws: ReviewError.reasonRequired) { try reviews.dismiss(openQuestion.stableID, reason: " \n\t") }
        let check = try #require(step5.reviews?.first { $0.verdict == .correct })
        #expect(throws: ReviewError.notAnObjection) { try reviews.dismiss(check.stableID, reason: "Fine.") }
        try reviews.dismiss(openQuestion.stableID, reason: "  The parity argument closes it.  ")
        #expect(openQuestion.dismissalReason == "The parity argument closes it.")
        #expect(openQuestion.dismissedByID == fixture.you.stableID)
        #expect(standing(step5).countsAsChecked)
        #expect(throws: ReviewError.notOpen) { try reviews.dismiss(openQuestion.stableID, reason: "Again.") }
        #expect(displayed(fixture.lemmas[2]) == .humanChecked)
    }

    @Test("Invariant 11: a newer revision closes the objection, so it can no longer be dismissed")
    func revisionClosesObjection() throws {
        let step5 = steps[4]
        try reviews.revise(step5.stableID, from: current(step5), text: step5.textLaTeX + " Spelled out.",
                           establishes: step5.establishes)
        #expect(standing(step5).human == .unchecked)
        #expect(throws: ReviewError.notOpen) { try reviews.dismiss(openQuestion.stableID, reason: "Answered.") }
    }

    @Test("Resolve dismisses and, if asked, checks in one change; it refuses as a whole")
    func resolve() async throws {
        let step5 = steps[4]
        let revision = contextRevision
        _ = await dirtyCount()
        #expect(throws: ReviewError.staleRevision) {
            try reviews.resolve(openQuestion.stableID, reason: "Fine.", alsoCheck: true, revision: UUID())
        }
        #expect(openQuestion.dismissedByID == nil, "nothing written when the ✓ is refused")
        try reviews.resolve(openQuestion.stableID, reason: "Fine.", alsoCheck: true, revision: current(step5))
        #expect(standing(step5).countsAsChecked)
        #expect(contextRevision == revision + 1)
        #expect(await dirtyCount() == 1)
        let check = try #require(step5.reviews?.first { $0.verdict == .correct })
        #expect(check.createdAt > openQuestion.dismissedAt!, "the ✓ follows the dismissal")
    }

    @Test("Resolve without the ✓ closes the objection and leaves the step unchecked")
    func resolveWithoutCheck() throws {
        try reviews.resolve(openQuestion.stableID, reason: "Fine.", alsoCheck: false, revision: current(steps[4]))
        #expect(standing(steps[4]).human == .unchecked)
    }

    @Test("Decisions made on text that changed are refused; a comment on an earlier version is kept on it")
    func staleRevisions() throws {
        let step5 = steps[4]
        let first = try #require((step5.revisions ?? []).min { $0.createdAt < $1.createdAt })
        #expect(throws: ReviewError.staleRevision) { try reviews.mark(.correct, step: step5.stableID, revision: first.stableID) }
        #expect(throws: ReviewError.staleRevision) {
            try reviews.revise(step5.stableID, from: first.stableID, text: "New.", establishes: "x")
        }
        let id = try reviews.comment("On the first version.", on: step5.stableID, revision: first.stableID)
        let comment = try #require(step5.comments?.first { $0.stableID == id })
        #expect(comment.revisionID == first.stableID && comment.author == .human(fixture.you.personID))
        let review = reviews.state(of: fixture.attemptA)[step: step5.stableID]!
        #expect(review.versionLabel(of: comment.revisionID) == "version 1")
    }

    @Test("Withdrawing: only my own ✓, it stops counting and stays in the history, and twice is once")
    func withdraw() async throws {
        let step1 = steps[0]
        let mine = try #require(step1.reviews?.first)
        let mk = try #require(steps[1].reviews?.first)
        #expect(throws: ReviewError.notYourReview) { try reviews.withdraw(mk.stableID) }
        _ = await dirtyCount()
        try reviews.withdraw(mine.stableID)
        #expect(standing(step1).human == .unchecked && standing(step1).withdrawnChecks.map(\.id) == [mine.stableID])
        #expect(displayed(fixture.lemmas[1]) == .humanChecked, "MK's ✓ on step 2 is untouched")
        #expect(await dirtyCount() == 1)
        let revision = contextRevision
        let at = mine.withdrawnAt
        try reviews.withdraw(mine.stableID)
        #expect(mine.withdrawnAt == at && contextRevision == revision)
        #expect(await dirtyCount() == 0)
        try reviews.mark(.correct, step: step1.stableID, revision: current(step1))
        #expect(standing(step1).countsAsChecked)
    }

    @Test("Invariant 11: the person who raised an objection may withdraw it; anyone else dismisses it with a reason")
    func withdrawObjection() async throws {
        let step5 = steps[4], step6 = steps[5]
        let theirs = Review(reviewer: fixture.mk.personID, verdict: .wrong, revisionReviewedID: current(step6))
        theirs.createdAt = Date(timeIntervalSinceReferenceDate: 850_000_000)
        fixture.state.container.mainContext.insert(theirs)
        theirs.step = step6
        #expect(throws: ReviewError.notYourReview) { try reviews.withdraw(theirs.stableID) }
        #expect(standing(step6).human == .objected)

        _ = await dirtyCount()
        let revision = contextRevision
        try reviews.withdraw(openQuestion.stableID)
        #expect(openQuestion.withdrawnAt != nil && openQuestion.dismissedAt == nil)
        #expect(standing(step5).human == .unchecked && standing(step5).withdrawnObjections.map(\.id) == [openQuestion.stableID])
        #expect(contextRevision == revision + 1)
        #expect(await dirtyCount() == 1)
        #expect(throws: ReviewError.notOpen) { try reviews.withdraw(openQuestion.stableID) }
        let history = reviews.state(of: fixture.attemptA).steps[4].history
        #expect(history.contains { if case .withdrawal(let review) = $0.kind { review.id == openQuestion.stableID } else { false } })
    }

    @Test("Undo takes back a mark made in this session, while nothing has been recorded on its step since")
    func undoMark() async throws {
        let step6 = steps[5]
        let context = fixture.state.container.mainContext
        let before = try context.fetchCount(FetchDescriptor<Review>())
        guard case .recorded(let id) = try reviews.mark(.unclear, step: step6.stableID, revision: current(step6)) else {
            Issue.record("recorded")
            return
        }
        #expect(standing(step6).human == .objected)
        _ = await dirtyCount()
        let revision = contextRevision
        try reviews.undoMark(id)
        #expect(try context.fetchCount(FetchDescriptor<Review>()) == before, "as if never given")
        #expect(standing(step6).human == .unchecked)
        #expect(contextRevision == revision + 1)
        #expect(await dirtyCount() == 1)
        #expect(throws: ReviewError.noSuchReview) { try reviews.undoMark(id) }

        // A mark from before this session, or one with something recorded after it, stays: withdraw it instead.
        #expect(throws: ReviewError.cannotUndo) { try reviews.undoMark(steps[0].reviews!.first!.stableID) }
        guard case .recorded(let commented) = try reviews.mark(.wrong, step: step6.stableID, revision: current(step6)) else {
            Issue.record("recorded")
            return
        }
        try reviews.comment("Why 8 elements?", on: step6.stableID, revision: current(step6))
        #expect(throws: ReviewError.cannotUndo) { try reviews.undoMark(commented) }
        #expect(standing(step6).human == .objected)
    }

    @Test("Edit > Undo takes back the mark and Redo gives it again; a refusal is reported, not swallowed")
    func undoManager() throws {
        let step6 = steps[5]
        let undo = UndoManager()
        undo.groupsByEvent = false
        func markWithUndo(_ verdict: ReviewVerdict) throws -> UUID? {
            undo.beginUndoGrouping()
            defer { undo.endUndoGrouping() }
            guard case .recorded(let id) = try reviews.mark(verdict, step: step6.stableID, revision: current(step6)) else {
                return nil
            }
            reviews.registerUndo(of: id, verdict: verdict, step: step6.stableID, revision: current(step6), in: undo) { _ in }
            return id
        }
        _ = try markWithUndo(.correct)
        #expect(standing(step6).countsAsChecked && undo.undoActionName == "Mark Correct")
        undo.undo()
        #expect(standing(step6).human == .unchecked)
        #expect(undo.canRedo)
        undo.redo()
        #expect(standing(step6).countsAsChecked, "redo gives the ✓ again, on the same version")
        undo.undo()
        #expect(standing(step6).human == .unchecked)

        var refusals: [ReviewError] = []
        undo.beginUndoGrouping()
        guard case .recorded(let id) = try reviews.mark(.unclear, step: step6.stableID, revision: current(step6)) else {
            Issue.record("recorded")
            return
        }
        reviews.registerUndo(of: id, verdict: .unclear, step: step6.stableID, revision: current(step6), in: undo) {
            refusals.append($0)
        }
        undo.endUndoGrouping()
        try reviews.comment("A note after it.", on: step6.stableID, revision: current(step6))
        undo.undo()
        #expect(refusals == [.cannotUndo])
        #expect(standing(step6).human == .objected)
    }

    @Test("Pressing the same verdict again records nothing; a different objection is a second one")
    func repeats() throws {
        let step1 = steps[0]
        let count = step1.reviews?.count
        #expect(try reviews.mark(.correct, step: step1.stableID, revision: current(step1)) == .alreadyChecked)
        #expect(step1.reviews?.count == count)
        let step5 = steps[4]
        #expect(try reviews.mark(.unclear, step: step5.stableID, revision: current(step5)) == .alreadyRaised)
        guard case .recorded = try reviews.mark(.wrong, step: step5.stableID, revision: current(step5)) else {
            Issue.record("a ✗ beside my ? is recorded")
            return
        }
        #expect(standing(step5).openObjections.count == 2)
    }

    @Test("Re-check: changing what step 2 establishes flags steps 3 and 4; a fresh ✓ clears the flag")
    func recheck() throws {
        let step2 = steps[1]
        try reviews.revise(step2.stableID, from: current(step2), text: step2.textLaTeX, establishes: "q > p, and q is odd")
        let state = reviews.state(of: fixture.attemptA)
        #expect(state.steps.map { $0.standing.recheck?.stepIndices ?? [] } == [[], [], [2], [2], [], []])
        #expect(state.progress.headline == "3 of 6 steps checked by a person")
        #expect(state.progress.notes == ["1 with an open objection", "2 flagged for re-check"])
        // Lem 6 rests on step 3 alone: still checked by a person, flag and all.
        #expect(fixture.state.graph.state(for: fixture.problem)[fixture.onRefutedClaim.stableID]?.derived.own
                == .humanChecked, "a flag changes no status")
        guard case .recorded = try reviews.mark(.correct, step: steps[2].stableID, revision: current(steps[2])) else {
            Issue.record("a flagged step takes a fresh ✓")
            return
        }
        #expect(standing(steps[2]).recheck == nil && standing(steps[3]).recheck != nil)
    }

    @Test("Withdrawing on a step checked twice (a fresh ✓ after a re-check) withdraws both")
    func withdrawBoth() throws {
        let step2 = steps[1], step3 = steps[2]
        try reviews.revise(step2.stableID, from: current(step2), text: step2.textLaTeX, establishes: "q > p, and q is odd")
        guard case .recorded(let fresh) = try reviews.mark(.correct, step: step3.stableID, revision: current(step3)) else {
            Issue.record("a flagged step takes a fresh ✓")
            return
        }
        #expect(standing(step3).checks.count == 2)
        try reviews.withdraw(fresh)
        #expect(standing(step3).human == .unchecked)
        #expect(standing(step3).withdrawnChecks.count == 2)
    }

    @Test("Repeating a ✓ beside an objection: an old ✓ is renewed if an earlier step changed, else kept")
    func repeatsBesideObjections() throws {
        let context = fixture.state.container.mainContext
        func object(_ step: Step) {
            let wrong = Review(reviewer: fixture.mk.personID, verdict: .wrong, revisionReviewedID: current(step))
            wrong.createdAt = Date(timeIntervalSinceReferenceDate: 850_000_000)
            context.insert(wrong)
            wrong.step = step
        }
        object(steps[3])
        #expect(try reviews.mark(.correct, step: steps[3].stableID, revision: current(steps[3])) == .alreadyChecked)
        #expect(standing(steps[3]).human == .objected)

        try reviews.revise(steps[1].stableID, from: current(steps[1]), text: steps[1].textLaTeX, establishes: "changed")
        #expect(standing(steps[3]).recheck == nil && standing(steps[3]).changedSinceCheck != nil)
        guard case .recorded = try reviews.mark(.correct, step: steps[3].stableID, revision: current(steps[3])) else {
            Issue.record("an old ✓ predating a change is renewed, objection or not")
            return
        }
        #expect(standing(steps[3]).changedSinceCheck == nil)
    }

    @Test("A referee request still running counts for the time floor (rule 4)")
    func floorOnRunningReferee() throws {
        let referee = Message(author: .model(fixture.slotC.slotID), kind: .referee)
        referee.createdAt = Date(timeIntervalSinceReferenceDate: 900_000_000)
        fixture.mainBranch.messages = (fixture.mainBranch.messages ?? []) + [referee]
        try reviews.revise(steps[5].stableID, from: current(steps[5]), text: "Spelled out.", establishes: steps[5].establishes)
        #expect(steps[5].latestRevision!.createdAt > referee.createdAt,
                "a verdict requested by that message cannot cover this revision")
    }

    @Test("Review shows the current revision's text, whatever the step's copy says")
    func textComesFromTheRevision() {
        steps[5].textLaTeX = "A stale copy."
        #expect(reviews.state(of: fixture.attemptA).steps[5].text == steps[5].latestRevision?.textLaTeX)
    }

    @Test("Comment drafts are kept per step")
    func drafts() {
        let draft = reviews.commentDraft(for: steps[0].stableID)
        draft.text = "Half a thought"
        #expect(reviews.commentDraft(for: steps[0].stableID) === draft)
        #expect(reviews.commentDraft(for: steps[1].stableID).text.isEmpty)
    }

    @Test("Re-check: a revision that keeps what the step establishes flags nothing")
    func noRecheck() throws {
        let step2 = steps[1]
        try reviews.revise(step2.stableID, from: current(step2), text: "Reworded.", establishes: "  q >  p ")
        #expect(reviews.state(of: fixture.attemptA).steps.allSatisfy { $0.standing.recheck == nil })
    }

    @Test("Refusals change nothing: no write, no context change, no save")
    func refusals() async throws {
        let context = fixture.state.container.mainContext
        func counts() throws -> [Int] {
            [try context.fetchCount(FetchDescriptor<Review>()), try context.fetchCount(FetchDescriptor<StepRevision>()),
             try context.fetchCount(FetchDescriptor<StepComment>())]
        }
        let before = try counts()
        let revision = contextRevision
        _ = await dirtyCount()
        let step6 = steps[5]
        #expect(throws: ReviewError.noSuchStep) { try reviews.mark(.correct, step: UUID(), revision: UUID()) }
        #expect(throws: ReviewError.noSuchReview) { try reviews.withdraw(UUID()) }
        #expect(throws: ReviewError.emptyText) {
            try reviews.revise(step6.stableID, from: current(step6), text: " ", establishes: "x")
        }
        #expect(throws: ReviewError.nothingChanged) {
            try reviews.revise(step6.stableID, from: current(step6), text: " \(step6.textLaTeX) ",
                               establishes: step6.establishes + " ")
        }
        #expect(throws: ReviewError.emptyComment) { try reviews.comment("  ", on: step6.stableID, revision: current(step6)) }
        #expect(throws: ReviewError.noSuchRevision) { try reviews.comment("Why?", on: step6.stableID, revision: UUID()) }
        #expect(try reviews.mark(.correct, step: steps[0].stableID, revision: current(steps[0])) == .alreadyChecked)
        #expect(try counts() == before)
        #expect(contextRevision == revision)
        #expect(await dirtyCount() == 0)
    }

    @Test("Each change is one context change and one save; a comment is a save only")
    func oneChangeEach() async throws {
        let step6 = steps[5]
        _ = await dirtyCount()
        var revision = contextRevision
        try reviews.mark(.unclear, step: step6.stableID, revision: current(step6))
        #expect(contextRevision == revision + 1)
        #expect(await dirtyCount() == 1)
        revision = contextRevision
        try reviews.comment("Why 8 elements?", on: step6.stableID, revision: current(step6))
        #expect(contextRevision == revision, "nothing a model is sent changed")
        #expect(await dirtyCount() == 1)
        try reviews.revise(step6.stableID, from: current(step6), text: "Spelled out.", establishes: step6.establishes)
        #expect(contextRevision == revision + 1)
        #expect(await dirtyCount() == 1)
    }

    @Test("Invariant 10: confidence never changes whether a ✓ is accepted or counts")
    func confidenceIsIgnored() throws {
        let step6 = steps[5]
        for confidence in Confidence.allCases {
            step6.confidence = confidence
            #expect(standing(step6).countsAsChecked == false)
        }
        step6.confidence = .guess
        try reviews.mark(.correct, step: step6.stableID, revision: current(step6))
        for confidence in Confidence.allCases {
            step6.confidence = confidence
            #expect(standing(step6).countsAsChecked)
            #expect(reviews.state(of: fixture.attemptA).progress.headline == "5 of 6 steps checked by a person")
        }
        #expect(reviews.state(of: fixture.attemptA).delicateStepIDs == [steps[4].stableID])
        step6.confidence = .delicate
        #expect(reviews.state(of: fixture.attemptA).delicateStepIDs == [steps[4].stableID, step6.stableID])
        #expect(!reviews.state(of: fixture.attemptA).uncheckedStepIDs.contains(step6.stableID))
    }

    /// Whether a view that read the attempt's review state would be asked to read it again after `change`.
    private func invalidates(_ change: () throws -> Void) rethrows -> Bool {
        let fired = Fired()
        let people = people
        withObservationTracking {
            _ = AttemptReviewState.read(attempt: fixture.attemptA, people: people)
        } onChange: {
            fired.value = true
        }
        try change()
        return fired.value
    }

    @Test("Views reading the review are told about a new review, comment, revision, withdrawal and dismissal")
    func observation() throws {
        let step6 = steps[5]
        #expect(try invalidates { try reviews.mark(.correct, step: step6.stableID, revision: current(step6)) })
        #expect(try invalidates { try reviews.comment("A note.", on: step6.stableID, revision: current(step6)) })
        #expect(try invalidates { try reviews.withdraw(steps[0].reviews!.first!.stableID) })
        #expect(try invalidates { try reviews.dismiss(openQuestion.stableID, reason: "Answered.") })
        #expect(try invalidates {
            try reviews.revise(step6.stableID, from: current(step6), text: "Spelled out.", establishes: step6.establishes)
        })
    }
}
