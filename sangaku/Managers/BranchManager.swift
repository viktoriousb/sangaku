import Foundation
import SwiftData

/// What is running, as `BranchManager` needs to know it: `ThreadManager` owns every request.
protocol BranchActivity: AnyObject {
    /// Messages still being written, queued ones included.
    var liveMessageIDs: Set<UUID> { get }
    /// Branches with a request running.
    var streamingBranchIDs: Set<UUID> { get }
}

extension ThreadManager: BranchActivity {}

/// Forks, dead ends, parking and reopening, the reasons written for a branch, and adopting an attempt as the main
/// line. The only writer of a branch's state and texts, of `Problem.mainBranchID` after a problem is made, and of
/// the adoption record. Every write is a person's action in the name of the person using the app: no parameter names
/// one, and nothing a model sends reaches here (invariant 1). The theorem's proof is set through `StatementGraph`, the
/// only writer of statements; nothing here cancels a request, which `ThreadManager` owns. Nothing is ever deleted.
@Observable
final class BranchManager {
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let saves: SaveScheduler
    @ObservationIgnored let problems: ProblemManager
    @ObservationIgnored let statements: StatementGraph
    @ObservationIgnored private let activity: BranchActivity
    @ObservationIgnored private let now: () -> Date

    init(context: ModelContext, saves: SaveScheduler, problems: ProblemManager, statements: StatementGraph,
         activity: BranchActivity, now: @escaping () -> Date = { .now }) {
        self.context = context
        self.saves = saves
        self.problems = problems
        self.statements = statements
        self.activity = activity
        self.now = now
    }

    // MARK: Forking

    /// A new branch forked from a message: it sees the message's branch's history up to and including that message,
    /// then its own (`BranchHistory`). Nothing is copied. Refused while the message, or one before it, is still
    /// being written. Forking changes nothing any prompt carries.
    @discardableResult
    func fork(from messageID: UUID, named name: String) throws(BranchError) -> Branch {
        guard let message = message(messageID), let owner = message.branch, let problem = owner.problem else {
            throw .noSuchMessage
        }
        let name = try validName(name, in: problem)
        let history = owner.visibleHistory
        if let fault = history.fault { throw .historyUnreadable(fault) }
        guard let position = history.position(of: messageID) else { throw .messageNotOnBranch }
        guard Set(history.ids[...position]).isDisjoint(with: activity.liveMessageIDs) else { throw .messageStillRunning }

        let branch = Branch(name: name, state: .live)
        // After every branch, so the order branches were made in never changes.
        branch.createdAt = Timestamps.after(problem.sortedBranches.last?.createdAt, now: now())
        context.insert(branch)
        branch.forkedFrom = message
        branch.parent = owner
        problem.branches = (problem.branches ?? []) + [branch]
        saves.markDirty()
        return branch
    }

    // MARK: Retiring and reopening

    /// Marks a branch a dead end with the reasons a person wrote. With "In context" on, its text goes into every
    /// prompt of the problem, so no model re-suggests it (invariant 5). Not the main line, and not while a request
    /// runs on it; once a dead end, its reasons can be edited at any time.
    func markDeadEnd(_ branch: Branch, _ draft: ReasonDraft) throws(BranchError) {
        try retire(branch, as: .deadEnd, draft)
    }

    /// Parks a branch, with an optional note for people. A parked branch is never sent to models.
    func park(_ branch: Branch, _ draft: ReasonDraft) throws(BranchError) {
        try retire(branch, as: .parked, draft)
    }

    /// Retires a branch as a dead end or parked: never the main line, and not while a request runs on it.
    private func retire(_ branch: Branch, as state: BranchState, _ draft: ReasonDraft) throws(BranchError) {
        let problem = try problem(of: branch)
        guard problem.mainBranchID != branch.stableID else { throw .isMainLine }
        let stateChanges = branch.state != state
        if stateChanges, activity.streamingBranchIDs.contains(branch.stableID) { throw .branchBusy }
        try validate(draft, for: branch, as: state)
        branch.state = state
        if state == .deadEnd { branch.includeReasonInContext = draft.includeInContext }
        write(draft, to: branch, models: state == .deadEnd)
        if stateChanges { stamp(branch) }
        changed(problem)
    }

    /// Reopens a dead end or parked branch. Its reasons are kept, as history; a reopened branch is not sent to
    /// models as a dead end.
    func reopen(_ branch: Branch) throws(BranchError) {
        let problem = try problem(of: branch)
        guard branch.state != .live else { return }
        branch.state = .live
        stamp(branch)
        changed(problem)
    }

    /// Edits a closed branch's reasons and, for a dead end, whether it is sent.
    func editReasons(of branch: Branch, _ draft: ReasonDraft) throws(BranchError) {
        let problem = try problem(of: branch)
        guard branch.state.isClosed else { throw .notClosed }
        try validate(draft, for: branch, as: branch.state)
        if branch.state == .deadEnd { branch.includeReasonInContext = draft.includeInContext }
        write(draft, to: branch, models: branch.state == .deadEnd)
        changed(problem)
    }

    /// Whether a dead end's text goes into every prompt.
    func setInContext(_ on: Bool, for branch: Branch) throws(BranchError) {
        let problem = try problem(of: branch)
        guard branch.state == .deadEnd else { throw .notADeadEnd }
        guard branch.includeReasonInContext != on else { return }
        if on, BranchReasons.trimmed(branch.reasonForModels) == nil, BranchReasons.trimmed(branch.reason) == nil {
            throw .reasonRequired
        }
        branch.includeReasonInContext = on
        changed(problem)
    }

    // MARK: Adopting

    /// What adopting an attempt would do and what to know first; nil when there is no such attempt. The Adopt sheet
    /// shows exactly this, and `adopt` refuses on the same terms.
    func assessment(ofAttempt id: UUID) -> AdoptionAssessment? {
        guard let attempt = attempt(id), let message = attempt.message, let branch = message.branch,
              let problem = branch.problem else { return nil }
        let steps = attempt.sortedSteps
        let standings = StepStandings.standings(of: steps, people: problems.personIDs())
        let ordered = steps.compactMap { standings[$0.stableID] }
        let running = activity.liveMessageIDs.contains(message.stableID)
        let refusal: BranchError? = if steps.isEmpty {
            .attemptHasNoSteps
        } else if running {
            .attemptStillRunning
        } else if branch.state.isClosed {
            .branchClosed(branch.state)
        } else if problem.adoptedAttemptID == id, problem.mainBranchID == branch.stableID {
            .alreadyAdopted
        } else {
            nil
        }
        return AdoptionAssessment(
            attemptID: id, branchID: branch.stableID, branchName: branch.name,
            branchIsMain: problem.mainBranchID == branch.stableID, stepCount: steps.count,
            warnings: AdoptionWarning.warnings(standings: ordered,
                                               partial: message.outcome(isStreaming: running).isPartial),
            progress: ReviewProgress(ordered), refusal: refusal)
    }

    /// Adopts an attempt as the main line: its steps become the theorem's proof (whose status then derives from
    /// them, never granted), the adoption is recorded, and the branch it was written on becomes the main line. Every
    /// warning must have been acknowledged, so a changed attempt is shown again before it is adopted.
    func adopt(attempt id: UUID, acknowledging: Set<AdoptionWarning>) throws(BranchError) {
        guard let assessment = assessment(ofAttempt: id), let attempt = attempt(id),
              let branch = attempt.message?.branch, let problem = branch.problem else { throw .noSuchAttempt }
        if let refusal = assessment.refusal { throw refusal }
        guard Set(assessment.warnings).isSubset(of: acknowledging) else { throw .warningsNotAcknowledged }
        do {
            try statements.adoptProof(attemptID: id, in: problem)
        } catch {
            throw .statement(error)
        }
        problem.mainBranchID = branch.stableID
        problem.adoptedAttemptID = id
        problem.adoptedByID = problems.me().stableID
        problem.adoptedAt = now()
        changed(problem)
    }

    // MARK: Cherry-picking

    /// What "Cherry-pick a step" opens the Promote sheet on: the branch's own attempts read as steps and finished.
    /// The lemma it makes refers to the original steps, so their reviews, verdict and authors count as they are.
    func cherryPickTarget(of branch: Branch) throws(BranchError) -> PromotionTarget {
        let attempts = branch.finishedAttempts(live: activity.liveMessageIDs)
        guard !attempts.isEmpty else { throw .nothingToCherryPick }
        return PromotionTarget(attemptIDs: attempts.map(\.stableID), stepID: nil)
    }

    // MARK: Lookup

    /// The branch with this stable ID, in whichever problem it is.
    func branch(_ id: UUID) -> Branch? {
        context.first(Branch.self, stableID: id)
    }

    // MARK: Helpers

    private func problem(of branch: Branch) throws(BranchError) -> Problem {
        guard let problem = branch.problem else { throw .noSuchBranch }
        return problem
    }

    /// One line, trimmed, and unused by any other branch of the problem, ignoring case.
    private func validName(_ name: String, in problem: Problem) throws(BranchError) -> String {
        let name = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw .emptyName }
        if (problem.branches ?? []).contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw .duplicateName(name)
        }
        return name
    }

    private func validate(_ draft: ReasonDraft, for branch: Branch, as state: BranchState) throws(BranchError) {
        if let refusal = draft.refusal(for: state) { throw refusal }
        let shown = Set(branch.visibleHistory.ids)
        for source in [draft.reasonFromMessageID, draft.modelTextFromMessageID].compactMap({ $0 }) {
            guard shown.contains(source) else { throw .messageNotOnBranch }
        }
    }

    /// Where one of a branch's two texts and its provenance are kept.
    private struct TextFields {
        let text: ReferenceWritableKeyPath<Branch, String?>
        let source: ReferenceWritableKeyPath<Branch, UUID?>
        let by: ReferenceWritableKeyPath<Branch, UUID?>
        let at: ReferenceWritableKeyPath<Branch, Date?>
    }

    private static let reasonFields = TextFields(text: \.reason, source: \.reasonFromMessageID, by: \.reasonByID,
                                                 at: \.reasonAt)
    private static let modelTextFields = TextFields(text: \.reasonForModels, source: \.modelTextFromMessageID,
                                                    by: \.modelTextByID, at: \.modelTextAt)

    /// Writes the texts that changed, each with who wrote it, when, and the message it was started from.
    private func write(_ draft: ReasonDraft, to branch: Branch, models: Bool) {
        write(draft.reason, from: draft.reasonFromMessageID, to: branch, Self.reasonFields)
        if models { write(draft.reasonForModels, from: draft.modelTextFromMessageID, to: branch, Self.modelTextFields) }
    }

    private func write(_ draft: String, from source: UUID?, to branch: Branch, _ fields: TextFields) {
        let text = BranchReasons.trimmed(draft)
        let source = text == nil ? nil : source
        guard text != branch[keyPath: fields.text] || source != branch[keyPath: fields.source] else { return }
        branch[keyPath: fields.text] = text
        branch[keyPath: fields.source] = source
        branch[keyPath: fields.by] = text == nil ? nil : problems.me().stableID
        branch[keyPath: fields.at] = text == nil ? nil : now()
    }

    private func stamp(_ branch: Branch) {
        branch.stateChangedByID = problems.me().stableID
        branch.stateChangedAt = now()
    }

    /// Dead ends, adoption and the theorem's proof are in every prompt: the composer's estimate is rebuilt.
    private func changed(_ problem: Problem) {
        problems.contextChanged(of: problem)
        saves.markDirty()
    }

    private func message(_ id: UUID) -> Message? {
        context.first(Message.self, stableID: id)
    }

    private func attempt(_ id: UUID) -> ProofAttempt? {
        context.first(ProofAttempt.self, stableID: id)
    }
}
