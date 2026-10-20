import Foundation
import SwiftData

/// Step reviews, objections and their dismissal, comments and person revisions. Every write is the action of the
/// person using the app (`problems.me()`): no parameter names a reviewer, and nothing a model sends reaches this
/// manager (invariant 1). Standings are derived on every read (`AttemptReviewState.read`), never stored.
@Observable
final class ReviewManager {
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let saves: SaveScheduler
    @ObservationIgnored let problems: ProblemManager
    @ObservationIgnored private let now: () -> Date
    /// Unsent comments by step, kept while the app runs, like the thread's composer drafts.
    @ObservationIgnored private var drafts: [UUID: CommentDraft] = [:]
    /// Marks recorded since the app opened: only these can be undone outright.
    @ObservationIgnored private var markedThisSession: Set<UUID> = []

    init(context: ModelContext, saves: SaveScheduler, problems: ProblemManager, now: @escaping () -> Date = { .now }) {
        self.context = context
        self.saves = saves
        self.problems = problems
        self.now = now
    }

    nonisolated enum MarkOutcome: Hashable, Sendable {
        case recorded(UUID)
        /// My ✓ already counts on this revision and nothing asks for a re-check: nothing was written.
        case alreadyChecked
        /// My open objection with this verdict is already on this revision: nothing was written.
        case alreadyRaised
    }

    /// The attempt as the Review screen shows it. Views pass the people they already observe.
    func state(of attempt: ProofAttempt, people: Set<UUID>? = nil) -> AttemptReviewState {
        AttemptReviewState.read(attempt: attempt, people: people ?? problems.personIDs())
    }

    /// The unsent comment on a step. It survives moving to another step or view.
    func commentDraft(for stepID: UUID) -> CommentDraft {
        if let draft = drafts[stepID] { return draft }
        let draft = CommentDraft()
        drafts[stepID] = draft
        return draft
    }

    // MARK: Verdicts

    /// Records my ✓, ✗ or ? on `revision`, which must still be the step's current revision. A ✓ never closes an
    /// open objection, mine or anyone's (invariant 11).
    @discardableResult
    func mark(_ verdict: ReviewVerdict, step id: UUID, revision: UUID) throws(ReviewError) -> MarkOutcome {
        let (step, problem) = try stepInProblem(id)
        let me = problems.me()
        let standing = try currentStanding(of: step, seen: revision)
        if let outcome = repeated(verdict, by: me.stableID, in: standing) { return outcome }

        let review = record(verdict, on: step, revision: revision, by: me)
        markedThisSession.insert(review)
        changed(problem)
        return .recorded(review)
    }

    /// Takes back a mark made since sangaku opened, as if it had never been given, while nothing has been recorded on
    /// its step after it. Anything older is withdrawn or dismissed instead, and stays in the history.
    func undoMark(_ id: UUID) throws(ReviewError) {
        let (review, step, problem) = try reviewInProblem(id)
        guard markedThisSession.contains(id), review.reviewerID == problems.me().stableID,
              review.withdrawnAt == nil, review.dismissedAt == nil,
              latestRecord(on: step, besides: review) < review.createdAt else { throw .cannotUndo }
        markedThisSession.remove(id)
        review.step = nil
        context.delete(review)
        changed(problem)
    }

    /// Undo and redo for a mark just recorded, in the window's undo manager (Edit > Undo, ⌘Z). Redo marks the same
    /// version again, with its own undo. A refusal (something recorded on the step since, or the step revised) is
    /// passed to `onRefusal`.
    func registerUndo(of id: UUID, verdict: ReviewVerdict, step: UUID, revision: UUID, in undoManager: UndoManager,
                      onRefusal: @escaping @MainActor (ReviewError) -> Void) {
        undoManager.registerUndo(withTarget: self) { manager in
            do throws(ReviewError) {
                try manager.undoMark(id)
                undoManager.registerUndo(withTarget: manager) { manager in
                    do throws(ReviewError) {
                        if case .recorded(let again) = try manager.mark(verdict, step: step, revision: revision) {
                            manager.registerUndo(of: again, verdict: verdict, step: step, revision: revision,
                                                 in: undoManager, onRefusal: onRefusal)
                        }
                    } catch {
                        onRefusal(error)
                    }
                }
                undoManager.setActionName("Mark \(verdict.title)")
            } catch {
                onRefusal(error)
            }
        }
        undoManager.setActionName("Mark \(verdict.title)")
    }

    /// Withdraws one of my marks; it stays in the history. A ✓: every ✓ I gave on that revision, since a fresh ✓ on
    /// a flagged step sits beside the older one; withdrawing twice changes nothing. A ✗ or ?: it closes, which only
    /// the person who raised it can do this way; anyone else dismisses it with a reason.
    func withdraw(_ id: UUID) throws(ReviewError) {
        let (review, step, problem) = try reviewInProblem(id)
        let me = problems.me().stableID
        guard review.reviewerID == me else { throw .notYourReview }
        guard review.verdict == .correct else {
            guard standing(of: step).openObjections.contains(where: { $0.id == review.stableID }) else { throw .notOpen }
            review.withdrawnAt = time(after: step)
            changed(problem)
            return
        }
        let mine = (step.reviews ?? []).filter {
            $0.verdict == .correct && $0.reviewerID == me && $0.revisionReviewedID == review.revisionReviewedID
                && $0.withdrawnAt == nil
        }
        guard !mine.isEmpty else { return }
        let at = time(after: step)
        for check in mine { check.withdrawnAt = at }
        changed(problem)
    }

    /// Closes an open ✗ or ? with a reason, as me. Any person may dismiss, not only the one who raised it.
    func dismiss(_ id: UUID, reason: String) throws(ReviewError) {
        let (review, step, problem) = try reviewInProblem(id)
        let reason = try openObjection(review, on: step, reason: reason)
        close(review, reason: reason, by: problems.me(), at: time(after: step))
        changed(problem)
    }

    /// Dismisses an open objection and, if asked, records my ✓ on `revision` in the same change. Nothing is written
    /// unless both are allowed.
    func resolve(_ id: UUID, reason: String, alsoCheck: Bool, revision: UUID) throws(ReviewError) {
        let (review, step, problem) = try reviewInProblem(id)
        let reason = try openObjection(review, on: step, reason: reason)
        let me = problems.me()
        var checks = false
        if alsoCheck {
            let standing = try currentStanding(of: step, seen: revision)
            checks = repeated(.correct, by: me.stableID, in: standing) == nil
        }
        close(review, reason: reason, by: me, at: time(after: step))
        if checks { _ = record(.correct, on: step, revision: revision, by: me) }
        changed(problem)
    }

    // MARK: Revisions and comments

    /// A new revision of the step by me, made from `revision`, which must still be current. Reviews of the old text
    /// stop counting (invariant 2); later steps whose ✓ predates a change in what this one establishes are flagged.
    func revise(_ id: UUID, from revision: UUID, text: String, establishes: String) throws(ReviewError) {
        let (step, problem) = try stepInProblem(id)
        guard let current = step.latestRevision else { throw .noRevision }
        guard current.stableID == revision else { throw .staleRevision }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let establishes = establishes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .emptyText }
        guard text != current.textLaTeX.trimmingCharacters(in: .whitespacesAndNewlines)
                || StepStandings.normalized(establishes) != StepStandings.normalized(current.establishes)
        else { throw .nothingChanged }

        let created = time(after: step)
        let new = StepRevision(author: .human(problems.me().personID), textLaTeX: text, establishes: establishes)
        new.createdAt = created
        context.insert(new)
        new.step = step
        step.textLaTeX = text
        step.establishes = establishes
        changed(problem)
    }

    /// A comment by me on one revision of the step; an earlier revision is allowed. Nothing a model is sent changes,
    /// so only a save is scheduled.
    @discardableResult
    func comment(_ body: String, on id: UUID, revision: UUID) throws(ReviewError) -> UUID {
        let (step, _) = try stepInProblem(id)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw .emptyComment }
        guard (step.revisions ?? []).contains(where: { $0.stableID == revision }) else { throw .noSuchRevision }
        let comment = StepComment(author: .human(problems.me().personID), body: body, revisionID: revision)
        comment.createdAt = time(after: step)
        context.insert(comment)
        comment.step = step
        saves.markDirty()
        return comment.stableID
    }

    // MARK: Helpers

    private func stepInProblem(_ id: UUID) throws(ReviewError) -> (Step, Problem) {
        guard let step = context.first(Step.self, stableID: id),
              let problem = step.attempt?.message?.branch?.problem else { throw .noSuchStep }
        return (step, problem)
    }

    private func reviewInProblem(_ id: UUID) throws(ReviewError) -> (Review, Step, Problem) {
        guard let review = context.first(Review.self, stableID: id), let step = review.step else { throw .noSuchReview }
        guard let problem = step.attempt?.message?.branch?.problem else { throw .noSuchStep }
        return (review, step, problem)
    }

    /// The step's standing, refusing a decision made on text that is no longer current.
    private func currentStanding(of step: Step, seen revision: UUID) throws(ReviewError) -> StepStanding {
        guard let current = step.latestRevision else { throw .noRevision }
        guard current.stableID == revision else { throw .staleRevision }
        return standing(of: step)
    }

    /// The step's standing within its attempt: a re-check flag depends on the steps before it.
    private func standing(of step: Step) -> StepStanding {
        StepStandings.standings(of: [step], people: problems.personIDs())[step.stableID]
            ?? StepStanding(id: step.stableID, index: step.index)
    }

    /// What pressing the same verdict again means: nothing new, or nil to record it. A ✓ older than a change to an
    /// earlier step is renewed, objection or not, so it is fresh once the objection closes.
    private func repeated(_ verdict: ReviewVerdict, by me: UUID, in standing: StepStanding) -> MarkOutcome? {
        if verdict == .correct {
            let mine = standing.checks.contains { $0.reviewerID == me }
            return mine && standing.changedSinceCheck == nil ? .alreadyChecked : nil
        }
        return standing.openObjections.contains { $0.reviewerID == me && $0.verdict == verdict } ? .alreadyRaised : nil
    }

    /// A ✗ or ? still open on the current revision, and a usable reason for closing it.
    private func openObjection(_ review: Review, on step: Step, reason: String) throws(ReviewError) -> String {
        guard review.verdict != .correct else { throw .notAnObjection }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw .reasonRequired }
        guard standing(of: step).openObjections.contains(where: { $0.id == review.stableID }) else { throw .notOpen }
        return reason
    }

    /// The time of the newest record on the step other than `review`: a revision, review, dismissal, withdrawal or
    /// comment.
    private func latestRecord(on step: Step, besides review: Review) -> Date {
        var latest = (step.revisions ?? []).map(\.createdAt).max() ?? .distantPast
        for other in step.reviews ?? [] where other !== review {
            latest = max(latest, other.createdAt, other.dismissedAt ?? .distantPast, other.withdrawnAt ?? .distantPast)
        }
        return max(latest, (step.comments ?? []).map(\.createdAt).max() ?? .distantPast)
    }

    private func record(_ verdict: ReviewVerdict, on step: Step, revision: UUID, by me: Person) -> UUID {
        let review = Review(reviewer: me.personID, verdict: verdict, revisionReviewedID: revision)
        review.createdAt = time(after: step)
        context.insert(review)
        review.step = step
        return review.stableID
    }

    private func close(_ review: Review, reason: String, by me: Person, at time: Date) {
        review.dismissalReason = reason
        review.dismissedByID = me.stableID
        review.dismissedAt = time
    }

    /// Now, but always after everything already recorded on the step's attempt (revisions, reviews, dismissals,
    /// withdrawals, comments, the referee's request and verdict times) and every message in its problem, a referee's
    /// request still running included: a referee on a fork may judge an attempt written on its parent. A clock
    /// running behind can then never make a person's revision look seen by the referee (rule 4), or a ✓ look older
    /// than the change it answers.
    private func time(after step: Step) -> Date {
        let steps = step.attempt?.steps ?? [step]
        var latest = step.attempt?.message?.branch?.problem?.latestMessageAt
            ?? (step.attempt?.message?.branch?.messages ?? []).map(\.createdAt).max() ?? .distantPast
        for step in steps {
            for revision in step.revisions ?? [] { latest = max(latest, revision.createdAt) }
            for review in step.reviews ?? [] {
                latest = max(latest, review.createdAt, review.dismissedAt ?? .distantPast, review.withdrawnAt ?? .distantPast)
            }
            for comment in step.comments ?? [] { latest = max(latest, comment.createdAt) }
        }
        for verdict in step.attempt?.verdicts ?? [] {
            latest = max(latest, verdict.createdAt, verdict.requestedAt ?? .distantPast)
        }
        return Timestamps.after(latest, now: now())
    }

    private func changed(_ problem: Problem) {
        problems.contextChanged(of: problem)
        saves.markDirty()
    }
}

/// An unsent comment on one step.
@Observable
final class CommentDraft {
    var text = ""
}
