import Foundation
import SwiftData

/// Messages per branch, the requests behind them, fan-outs, streaming and stopping. The only owner of request
/// tasks and of what requests write to the store.
///
/// `SendPlanner` builds every request of a send first; the send is then written in one change: the prompt, each
/// reply or attempt, and their `RequestRecord`s. Tokens go only to each request's `MessageStream`; the end of a
/// request, however it ends, writes its message once more. Streaming never touches the store, so a save in between
/// keeps a request whose `finishedAt` is unset, which reads as interrupted, never as complete.
///
/// An attempt or a referee is read (`OutputParsing`) after it ends and stays live until it has been, so nothing
/// reads it half-written. A fan-out's order is decided by its `FanOutRun`; this type carries out its commands.
@Observable
final class ThreadManager {
    /// Output reserved per request. Streaming keeps a long reply within HTTP timeouts.
    static let maxOutputTokens = 64_000

    /// Live requests by message stable ID, queued ones included. Changes only when a request starts or ends,
    /// never per token.
    private(set) var live: [UUID: MessageStream] = [:]
    /// The messages still being written, queued ones included.
    var liveMessageIDs: Set<UUID> { Set(live.keys) }
    private(set) var streamingBranchIDs: Set<UUID> = []
    /// Fan-outs still running or waiting for their referee, by fan-out stable ID.
    private(set) var runs: [UUID: FanOutRun] = [:]
    /// Why a referee chosen to follow a fan-out could not start, by fan-out stable ID.
    private(set) var refereeNotices: [UUID: String] = [:]

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let saves: SaveScheduler
    @ObservationIgnored let problems: ProblemManager
    @ObservationIgnored let credentials: CredentialManager
    @ObservationIgnored let registry: ProviderRegistry
    @ObservationIgnored let catalog: ModelCatalog
    @ObservationIgnored let prompts: PromptLibrary
    @ObservationIgnored let builder: ContextBuilder
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var active: [UUID: ActiveRequest] = [:]
    @ObservationIgnored private var drafts: [UUID: ComposerDraft] = [:]
    @ObservationIgnored private var calibrations: [String: (calibration: TokenCalibration, samples: Int)] = [:]
    /// Set while quitting: output is read at once, and nothing new starts.
    @ObservationIgnored private var shuttingDown = false

    private struct ActiveRequest {
        enum State {
            /// A later prover of a shared fan-out, waiting for its turn. Nothing has been sent.
            case queued
            case streaming
            /// Ended; its output is being read.
            case settling
        }

        enum Role {
            case reply
            case attempt(fanOutID: UUID)
            case referee(fanOutID: UUID, attempts: [AttemptRef])
            /// Keyed by its record's stable ID: an alignment has no message.
            case alignment(AlignmentBasis)
            /// A formalizer's Lean draft or a scout's computation, for one statement.
            case task(TaskBasis)
        }

        var state: State
        var task: Task<Void, Never>?
        let problemID: UUID
        let branchID: UUID
        let slot: ModelSlotID
        let role: Role
    }

    private enum Ending {
        case finished(StopReason, TokenUsage)
        case stopped(LocalStopReason)
        case failed(ProviderError)
    }

    private enum Parsed {
        case attempt(AttemptParse)
        case referee(RefereeReport?)
        case alignment(AlignmentReport?)
        case leanDraft(LeanDraftReport?)
        case computeCell(ComputeCellReport?)
    }

    init(context: ModelContext, saves: SaveScheduler, problems: ProblemManager, credentials: CredentialManager,
         registry: ProviderRegistry, catalog: ModelCatalog = .standard, prompts: PromptLibrary = .bundled,
         builder: ContextBuilder = ContextBuilder(), now: @escaping () -> Date = { Date.now }) {
        self.context = context
        self.saves = saves
        self.problems = problems
        self.credentials = credentials
        self.registry = registry
        self.catalog = catalog
        self.prompts = prompts
        self.builder = builder
        self.now = now
    }

    isolated deinit {
        for request in active.values { request.task?.cancel() }
    }

    /// The provider a problem's first slot is created for.
    var defaultProviderID: String { registry.descriptors.first?.id ?? ProviderID.anthropic }

    func draft(for branchID: UUID) -> ComposerDraft {
        if let draft = drafts[branchID] { return draft }
        let draft = ComposerDraft()
        drafts[branchID] = draft
        return draft
    }

    // MARK: Plan and send

    /// The composer's estimate: nothing leaves the Mac.
    func plan(problem: Problem, branch: Branch, draft: ComposerDraft) -> SendPlan {
        SendPlanner.plan(sendRequest(problem: problem, branch: branch, draft: draft), env: environment(for: problem))
    }

    /// Sends the draft to the chosen provers: a prose reply from one, or a fan-out of attempts and perhaps a
    /// referee. Throws why it could not, having changed nothing.
    func send(problem: Problem, branch: Branch, draft: ComposerDraft) throws(SendBlocker) {
        let ready = try SendPlanner.ready(sendRequest(problem: problem, branch: branch, draft: draft),
                                          env: environment(for: problem))
        commit(ready, problem: problem, branch: branch)
        draft.text = ""
        begin(ready, problemID: problem.stableID, branchID: branch.stableID)
    }

    /// Starts the referee over a fan-out's attempts by hand ("Referee with C"): after Stop all, when no referee was
    /// chosen, or to referee again. Refused while anything runs on the branch.
    func referee(_ fanOut: FanOut, with slot: ModelSlot, problem: Problem, branch: Branch,
                 effort: ThinkingEffort) throws(SendBlocker) {
        guard !streamingBranchIDs.contains(branch.stableID) else { throw .busy }
        let members = (fanOut.attempts ?? []).compactMap(\.message).sorted { $0.createdAt < $1.createdAt }.map(\.stableID)
        var run = runs[fanOut.stableID] ?? FanOutRun.settled(fanOutID: fanOut.stableID, problemID: problem.stableID,
                                                             branchID: branch.stableID, members: members, effort: effort)
        guard run.handle(.refereeRequested(slotID: slot.stableID)) == [.startReferee(slotID: slot.stableID)] else {
            throw .busy
        }
        runs[fanOut.stableID] = run
        refereeNotices[fanOut.stableID] = nil
        do {
            try startReferee(fanOutID: fanOut.stableID, slotID: slot.stableID, run: run)
        } catch {
            runs[fanOut.stableID] = nil
            throw error
        }
    }

    /// A send on a branch: its time comes after everything the branch shows, inherited messages included, so the
    /// new messages always follow its history.
    private func sendRequest(problem: Problem, branch: Branch, draft: ComposerDraft) -> SendRequest {
        SendRequest(snapshot: snapshot(problem: problem, branch: branch), selection: draft.selection,
                    text: draft.text, effort: draft.effort, busy: streamingBranchIDs.contains(branch.stableID),
                    now: Timestamps.after(branch.visibleHistory.latestDate, now: now()))
    }

    private func environment(for problem: Problem) -> PlannerEnvironment {
        var env = PlannerEnvironment(catalog: catalog, prompts: prompts, builder: builder, registry: registry,
                                     maxOutputTokens: Self.maxOutputTokens)
        var models = Set(problem.sortedModelSlots.map(\.modelID))
        if let model = catalog.defaultModel(for: env.defaultProviderID) { models.insert(model.id) }
        for model in models { env.calibrations[model] = calibration(for: model) }
        env.providersWithoutKey = Set(registry.descriptors.map(\.id).filter { credentials.state(for: $0) == .missing })
        return env
    }

    /// The whole send as one change to the store.
    private func commit(_ ready: ReadySend, problem: Problem, branch: Branch) {
        if let slot = ready.newSlot {
            problems.addSlot(to: problem, providerID: slot.providerID, modelID: slot.modelID, stableID: slot.id.rawValue)
        }
        let prompt = Message(author: .human(problems.me().personID), bodyLaTeX: ready.text, kind: .prompt)
        prompt.stableID = ready.promptID
        prompt.createdAt = ready.promptCreatedAt
        prompt.derivedFromIDs = ready.promptDerivedFromIDs
        var fanOut: FanOut?
        if case .fanOut(let visibility) = ready.kind, let id = ready.fanOutID {
            let created = FanOut(visibility: visibility)
            created.stableID = id
            created.createdAt = ready.promptCreatedAt
            created.refereeSlotID = ready.referee?.id.rawValue
            prompt.fanOut = created
            fanOut = created
        }
        var messages = [prompt]
        for (index, member) in ready.members.enumerated() {
            let message = Message(author: .model(member.slot.id), kind: fanOut == nil ? ready.replyKind : .attempt)
            message.stableID = member.messageID
            message.createdAt = member.createdAt
            message.derivedFromIDs = [prompt.stableID]
            let record = RequestRecord()
            record.createdAt = ready.promptCreatedAt
            // A later prover of a shared fan-out records what it was sent when its turn comes.
            describe(record, member.prepared, sent: fanOut?.visibility != .shared || index == 0)
            message.request = record
            if let fanOut {
                let attempt = ProofAttempt()
                attempt.fanOut = fanOut
                message.proofAttempt = attempt
            }
            messages.append(message)
        }
        branch.messages = (branch.messages ?? []) + messages
        saves.markDirty()
    }

    /// What a request is, on its record; `sent` adds exactly what the model was given.
    private func describe(_ record: RequestRecord, _ prepared: PreparedRequest, sent: Bool) {
        let request = prepared.request
        record.providerID = request.providerID
        record.modelID = request.modelID
        record.parametersJSON = JSONColumn.encode(RequestParameters(
            model: request.modelID, maxOutputTokens: request.maxOutputTokens, effort: request.effort, stream: true,
            apiVersion: AnthropicWire.apiVersion, thinking: AnthropicWire.thinkingDescription,
            outputFormat: request.format?.tag))
        record.promptVersion = prepared.built.promptVersion
        guard sent else { return }
        record.contextText = prepared.built.transcript
        record.droppedItems = prepared.built.dropped
        record.estimatedInputTokens = prepared.built.totalTokens
    }

    private func begin(_ ready: ReadySend, problemID: UUID, branchID: UUID) {
        guard let fanOutID = ready.fanOutID, case .fanOut(let visibility) = ready.kind else {
            for member in ready.members {
                start(member.prepared.request, messageID: member.messageID, problemID: problemID, branchID: branchID,
                      slot: member.slot.id, role: .reply)
            }
            return
        }
        let (run, commands) = FanOutRun.begin(
            fanOutID: fanOutID, problemID: problemID, branchID: branchID, members: ready.members.map(\.messageID),
            sequential: visibility == .shared, refereeSlotID: ready.referee?.id.rawValue, effort: ready.effort)
        runs[fanOutID] = run
        refereeNotices[fanOutID] = nil
        for member in ready.members {
            if commands.contains(.startMember(member.messageID)) {
                start(member.prepared.request, messageID: member.messageID, problemID: problemID, branchID: branchID,
                      slot: member.slot.id, role: .attempt(fanOutID: fanOutID))
            } else {
                live[member.messageID] = MessageStream(phase: .queued)
                active[member.messageID] = ActiveRequest(state: .queued, problemID: problemID, branchID: branchID,
                                                         slot: member.slot.id, role: .attempt(fanOutID: fanOutID))
            }
        }
        updateStreamingBranches()
    }

    // MARK: Requests

    private func start(_ request: ProviderRequest, messageID: UUID, problemID: UUID, branchID: UUID,
                       slot: ModelSlotID, role: ActiveRequest.Role) {
        let stream = MessageStream()
        live[messageID] = stream
        active[messageID] = ActiveRequest(state: .streaming, problemID: problemID, branchID: branchID, slot: slot,
                                          role: role)
        updateStreamingBranches()
        // Prepared requests were checked against the registry, which never changes.
        guard let provider = registry.provider(for: request) else {
            finish(messageID, .failed(.transport("No provider named \(request.providerID) is available.")))
            return
        }
        let events = provider.stream(request)
        // Inherits the main actor: events arrive here in order, and the store is only written on this actor.
        active[messageID]?.task = Task { [weak self] in
            do {
                for try await event in events {
                    guard let self, self.active[messageID]?.state == .streaming else { return }
                    stream.apply(event)
                    if case .finished(let reason, let usage) = event {
                        self.finish(messageID, .finished(reason, usage))
                        return
                    }
                }
                // A cancelled stream ends quietly instead of throwing.
                self?.finish(messageID, Task.isCancelled ? .stopped(.stopped) : .failed(.incomplete))
            } catch {
                let stopped = Task.isCancelled || error is CancellationError
                self?.finish(messageID, stopped ? .stopped(.stopped)
                    : .failed(error as? ProviderError ?? .transport(error.localizedDescription)))
            }
        }
    }

    /// A later prover of a shared fan-out, now that the ones before it have ended: its context is built afresh, so
    /// it sees their attempts.
    private func startQueued(_ id: UUID, run: FanOutRun) {
        guard let request = active[id], request.state == .queued else { return }
        guard let problem = problems.problem(id: run.problemID),
              let branch = problem.sortedBranches.first(where: { $0.stableID == run.branchID }),
              let record = fetchMessage(id)?.request else {
            complete(id)
            return
        }
        let snapshot = snapshot(problem: problem, branch: branch)
        do throws(SendBlocker) {
            guard let slot = snapshot.slot(request.slot) else { throw .slotMissing }
            let prepared = try RequestPreparer.prepare(
                RequestSpec(slot: slot, kind: .attempt(fanOut: run.fanOutID), effort: run.effort),
                snapshot: snapshot, env: environment(for: problem))
            record.createdAt = now()
            describe(record, prepared, sent: true)
            saves.markDirty()
            start(prepared.request, messageID: id, problemID: run.problemID, branchID: run.branchID, slot: request.slot,
                  role: request.role)
        } catch {
            // Recorded as a request that failed before it was sent; the fan-out moves on.
            record.errorKind = "not_sent"
            record.errorMessage = error.message
            record.finishedAt = now()
            saves.markDirty()
            complete(id)
        }
    }

    private func startReferee(fanOutID: UUID, slotID: UUID, run: FanOutRun) throws(SendBlocker) {
        guard let problem = problems.problem(id: run.problemID),
              let branch = problem.sortedBranches.first(where: { $0.stableID == run.branchID }) else {
            throw .context(.fanOutNotOnBranch(fanOutID))
        }
        let snapshot = snapshot(problem: problem, branch: branch)
        guard let slot = snapshot.slots.first(where: { $0.id.rawValue == slotID }) else { throw .slotMissing }
        if credentials.state(for: slot.providerID) == .missing {
            throw .missingKey(providerName: registry.displayName(for: slot.providerID))
        }
        let prepared = try RequestPreparer.prepare(RequestSpec(slot: slot, kind: .referee(fanOut: fanOutID), effort: run.effort),
                                                   snapshot: snapshot, env: environment(for: problem))
        guard let fanOut = snapshot.fanOut(fanOutID) else { throw .context(.fanOutNotOnBranch(fanOutID)) }
        let attempts: [AttemptRef] = fanOut.attemptMessageIDs.compactMap { id in
            guard let attempt = snapshot.message(id), case .model(let author) = attempt.author,
                  let letter = snapshot.slot(author)?.letter else { return nil }
            let declined = if case .declined = attempt.outcome { true } else { false }
            let hasText = !attempt.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attempt.steps.isEmpty
            return AttemptRef(messageID: id, letter: letter, stepCount: attempt.steps.count,
                              partial: prepared.built.partialAttemptIDs.contains(id), hasContent: hasText && !declined)
        }
        let message = Message(author: .model(slot.id), kind: .referee)
        let last = branch.visibleHistory.latestDate
        message.createdAt = Timestamps.after(last, now: now())
        message.derivedFromIDs = (fanOut.requestMessageID.map { [$0] } ?? []) + fanOut.attemptMessageIDs
        let record = RequestRecord()
        record.createdAt = message.createdAt
        describe(record, prepared, sent: true)
        message.request = record
        branch.messages = (branch.messages ?? []) + [message]
        saves.markDirty()
        start(prepared.request, messageID: message.stableID, problemID: run.problemID, branchID: run.branchID,
              slot: slot.id, role: .referee(fanOutID: fanOutID, attempts: attempts))
    }

    // MARK: Questions about attempts

    /// Sends a person's question about attempts to one slot: the author of a step, to repair it, or a referee, to
    /// judge one row of a comparison. An ordinary prose exchange in the thread. Its prompt is linked to the attempts
    /// (`derivedFromIDs`), so wherever those attempts are withheld from a model (invariant 4), so is the exchange.
    /// Refused while either attempt is still being written, and with every check of a send; a refusal writes nothing.
    @discardableResult
    func ask(_ text: String, slot slotID: UUID, about attemptMessageIDs: [UUID], problem: Problem, branch: Branch,
             effort: ThinkingEffort) throws(SendBlocker) -> UUID {
        let running = attemptMessageIDs.filter { live[$0] != nil }
        guard running.isEmpty else { throw .context(.attemptsUnfinished(running)) }
        let snapshot = snapshot(problem: problem, branch: branch)
        guard let slot = snapshot.slots.first(where: { $0.id.rawValue == slotID }) else { throw .slotMissing }
        let last = branch.visibleHistory.latestDate
        let ready = try SendPlanner.readyQuestion(
            text, to: slot, about: attemptMessageIDs, snapshot: snapshot, effort: effort,
            busy: streamingBranchIDs.contains(branch.stableID), now: Timestamps.after(last, now: now()),
            env: environment(for: problem))
        commit(ready, problem: problem, branch: branch)
        begin(ready, problemID: problem.stableID, branchID: branch.stableID)
        return ready.members[0].messageID
    }

    // MARK: Formalizer and scout

    /// What a formalizer's or a scout's request would send and cost, or why it cannot be sent now.
    func taskPlan(_ basis: TaskBasis, slot slotID: UUID, problem: Problem, branch: Branch,
                  effort: ThinkingEffort) -> Result<SendPlan.Recipient, SendBlocker> {
        do throws(SendBlocker) {
            let (prepared, slot) = try prepareTask(basis, slot: slotID, problem: problem, branch: branch, effort: effort)
            return .success(SendPlanner.estimate(prepared, letter: slot.letter, env: environment(for: problem)))
        } catch {
            return .failure(error)
        }
    }

    /// Asks a formalizer for Lean code, or a scout for a computation, for one statement. The model's message is written
    /// on the branch, derived from the attempts the statement came from, and carries the draft or the cell once its
    /// answer is read. Nothing runs and nothing is checked: a person clicks Check or Run on what they are shown
    /// (invariants 1 and 14). Refused, writing nothing, when the branch is busy, the slot has another role, the
    /// provider is not allowed (invariant 15), no key is stored, or an attempt is still being written (invariant 4).
    @discardableResult
    func requestTask(_ basis: TaskBasis, slot slotID: UUID, problem: Problem, branch: Branch,
                     effort: ThinkingEffort) throws(SendBlocker) -> UUID {
        let (prepared, slot) = try prepareTask(basis, slot: slotID, problem: problem, branch: branch, effort: effort)
        let message = Message(author: .model(slot.id), kind: basis.messageKind)
        message.createdAt = Timestamps.after(branch.visibleHistory.latestDate, now: now())
        message.derivedFromIDs = basis.sourceMessageIDs
        let record = RequestRecord()
        record.createdAt = message.createdAt
        describe(record, prepared, sent: true)
        message.request = record
        branch.messages = (branch.messages ?? []) + [message]
        saves.markDirty()
        start(prepared.request, messageID: message.stableID, problemID: problem.stableID, branchID: branch.stableID,
              slot: slot.id, role: .task(basis))
        return message.stableID
    }

    private func prepareTask(_ basis: TaskBasis, slot slotID: UUID, problem: Problem, branch: Branch,
                             effort: ThinkingEffort) throws(SendBlocker) -> (PreparedRequest, ProblemSnapshot.SlotDigest) {
        guard !streamingBranchIDs.contains(branch.stableID) else { throw .busy }
        let running = basis.sourceMessageIDs.filter { live[$0] != nil }
        guard running.isEmpty else { throw .context(.attemptsUnfinished(running)) }
        let snapshot = snapshot(problem: problem, branch: branch)
        guard let slot = snapshot.slots.first(where: { $0.id.rawValue == slotID }) else { throw .slotMissing }
        let env = environment(for: problem)
        try SendPlanner.checkProvider(of: slot, snapshot: snapshot, env: env)
        let prepared = try RequestPreparer.prepare(RequestSpec(slot: slot, kind: .task(basis), effort: effort),
                                                   snapshot: snapshot, env: env)
        return (prepared, slot)
    }

    /// A formalizer's draft or a scout's cell, attached to its message; the note becomes the message's text. An answer
    /// that cannot be read keeps its raw text and gets neither, so nothing can be checked or run from it.
    private func apply(_ parsed: Parsed, to message: Message, basis: TaskBasis) {
        guard let record = message.request else { return }
        switch parsed {
        case .leanDraft(let report?):
            message.leanDraft = LeanDraft(statementID: basis.statementID, statementPart: report.source.statementPart,
                                          proofPart: report.source.proofPart)
            message.leanDraft?.createdAt = message.createdAt
            message.bodyLaTeX = report.note
            record.parseState = .clean
        case .computeCell(let report?):
            let cell = ComputeCell(tool: report.tool, code: report.code, scope: report.scope, claim: report.claim,
                                   statementID: basis.statementID)
            cell.createdAt = message.createdAt
            message.computeCell = cell
            message.bodyLaTeX = report.note
            record.parseState = .clean
        default:
            record.parseState = .unstructured
        }
    }

    // MARK: Alignment

    /// What aligning two attempts would send and cost, or why it cannot be sent now. Nothing leaves the Mac.
    func alignPlan(_ pair: ComparedPair, aligner: UUID, problem: Problem, branch: Branch,
                   effort: ThinkingEffort) -> Result<SendPlan.Recipient, SendBlocker> {
        do throws(SendBlocker) {
            let (prepared, slot, _) = try prepareAlignment(pair, aligner: aligner, problem: problem, branch: branch,
                                                           effort: effort)
            return .success(SendPlanner.estimate(prepared, letter: slot.letter, env: environment(for: problem)))
        } catch {
            return .failure(error)
        }
    }

    /// Asks a referee-role slot that wrote neither attempt to align two attempts for Compare, in the order Compare
    /// shows them whatever order they are passed in. The request's record belongs to the comparison, not to a
    /// message, so nothing of it enters the thread or any later context. Refused, writing nothing, when the branch
    /// is busy, the two attempts are one, an attempt is still being written (invariant 4), the slot may not align
    /// them, the provider is not allowed (invariant 15) or no key is stored. The answer is stored when the request
    /// ends (`apply(_:basis:record:aligner:)`).
    @discardableResult
    func align(_ pair: ComparedPair, aligner: UUID, problem: Problem, branch: Branch,
               effort: ThinkingEffort) throws(SendBlocker) -> UUID {
        let (prepared, slot, basis) = try prepareAlignment(pair, aligner: aligner, problem: problem, branch: branch,
                                                           effort: effort)
        let alignment = problem.alignment(for: basis.pair, creatingIn: context, at: now())
        let record = RequestRecord()
        record.createdAt = now()
        describe(record, prepared, sent: true)
        context.insert(record)
        record.alignment = alignment
        saves.markDirty()
        start(prepared.request, messageID: record.stableID, problemID: problem.stableID, branchID: branch.stableID,
              slot: slot.id, role: .alignment(basis))
        return record.stableID
    }

    private func prepareAlignment(_ pair: ComparedPair, aligner: UUID, problem: Problem, branch: Branch,
                                  effort: ThinkingEffort)
        throws(SendBlocker) -> (PreparedRequest, ProblemSnapshot.SlotDigest, AlignmentBasis) {
        guard !streamingBranchIDs.contains(branch.stableID) else { throw .busy }
        guard pair.first != pair.second else { throw .compare(.notAPair) }
        let pair = problem.orientation(of: pair.first, pair.second)
        guard let first = attempt(pair.first), let second = attempt(pair.second),
              let basis = AlignmentBasis.make(pair, first: first, second: second) else {
            throw .context(.attemptNotOnBranch(pair.first))
        }
        let snapshot = snapshot(problem: problem, branch: branch)
        guard let slot = snapshot.slots.first(where: { $0.id.rawValue == aligner }) else { throw .slotMissing }
        guard slot.role == .referee, !AlignerChoice.authorSlots(first, second).contains(aligner) else {
            throw .compare(.noAligner)
        }
        let env = environment(for: problem)
        try SendPlanner.checkProvider(of: slot, snapshot: snapshot, env: env)
        let prepared = try RequestPreparer.prepare(RequestSpec(slot: slot, kind: .align(basis), effort: effort),
                                                   snapshot: snapshot, env: env)
        return (prepared, slot, basis)
    }

    /// An aligner's answer, mapped failing closed (`AlignmentMapper`), replaces the comparison's model rows. An answer
    /// with nothing usable leaves the earlier rows; a person's corrections and blind verdict are never touched.
    private func apply(_ report: AlignmentReport?, basis: AlignmentBasis, record: RequestRecord, aligner: ModelSlotID) {
        guard let report, let alignment = record.alignment, alignment.attemptAID == basis.first.attemptID,
              let draft = AlignmentMapper.map(report, basis: basis) else {
            record.parseState = .unstructured
            return
        }
        alignment.rows = draft.rows
        alignment.modelSummary = draft.summary
        alignment.modelRunID = record.stableID
        alignment.alignerSlotID = aligner.rawValue
        record.parseState = .clean
    }

    // MARK: Stop

    /// Stops a request. What arrived is kept and marked interrupted; a fan-out's referee still follows.
    func stop(messageID: UUID) {
        stop(messageID, reason: .stopped)
    }

    /// Stops everything on a branch, and cancels any referee still waiting there.
    func stop(branchID: UUID) {
        for (fanOutID, run) in runs where run.branchID == branchID { advance(fanOutID, .stopAll) }
        for (id, request) in active where request.branchID == branchID { stop(id, reason: .stopped) }
    }

    /// Before quitting: every live request is kept as interrupted and read, ready for the final save. Nothing new
    /// starts.
    func stopAllForQuit() {
        shuttingDown = true
        defer { shuttingDown = false }
        for fanOutID in Array(runs.keys) { advance(fanOutID, .shutdown) }
        for (id, request) in active where request.state == .settling {
            request.task?.cancel()
            settleNow(id)
        }
        for id in Array(active.keys) { stop(id, reason: .appQuit) }
    }

    /// A problem is about to be deleted: its requests stop without writing anything.
    func cancelAll(problemID: UUID) {
        for (id, request) in active where request.problemID == problemID {
            request.task?.cancel()
            active[id] = nil
            live[id] = nil
        }
        for (fanOutID, run) in runs where run.problemID == problemID {
            runs[fanOutID] = nil
            refereeNotices[fanOutID] = nil
        }
        updateStreamingBranches()
    }

    private func stop(_ id: UUID, reason: LocalStopReason) {
        guard let request = active[id] else { return }
        switch request.state {
        case .queued:
            // Never sent: there is nothing to keep.
            if let message = fetchMessage(id), let record = message.request {
                message.interrupted = true
                record.stopReason = reason.rawValue
                record.finishedAt = now()
                saves.markDirty()
            }
            complete(id)
        case .streaming:
            finish(id, .stopped(reason))
            request.task?.cancel()
        case .settling:
            // The output is complete and being read.
            break
        }
    }

    /// Requests that never ended (the app quit or crashed mid-stream) become interrupted, and say so: the messages
    /// the branch shows, inherited ones included, and the alignment requests of its problem.
    func reconcileOrphans(in branch: Branch) {
        var changed = false
        for message in branch.visibleHistory.all where active[message.stableID] == nil {
            guard let record = message.request, record.finishedAt == nil else { continue }
            record.finishedAt = now()
            record.stopReason = LocalStopReason.orphaned.rawValue
            message.interrupted = true
            changed = true
        }
        for alignment in branch.problem?.alignments ?? [] {
            for record in alignment.requests ?? [] where record.finishedAt == nil && active[record.stableID] == nil {
                record.finishedAt = now()
                record.stopReason = LocalStopReason.orphaned.rawValue
                changed = true
            }
        }
        if changed { saves.markDirty() }
    }

    // MARK: Finishing

    /// Runs once per request, however it ends: writes the message and its record. A reply is then done; an attempt
    /// or a referee is read first, off the main actor, and stays live until it has been.
    private func finish(_ id: UUID, _ ending: Ending) {
        guard var request = active[id], request.state == .streaming else { return }
        let stream = live[id]
        stream?.flush()
        // An alignment writes only its record; every other request writes its message too.
        let message: Message?
        let record: RequestRecord
        if case .alignment = request.role {
            guard let found = fetchRecord(id) else {
                complete(id)
                return
            }
            (message, record) = (nil, found)
        } else {
            guard let found = fetchMessage(id), let foundRecord = found.request else {
                complete(id)
                return
            }
            (message, record) = (found, foundRecord)
        }
        let text = stream?.fullText ?? ""
        message?.bodyLaTeX = text
        record.answeredModelID = stream?.answeredModel.flatMap { $0.isEmpty ? nil : $0 }
        record.finishedAt = now()
        var usage = stream?.usage ?? TokenUsage()
        switch ending {
        case .finished(let reason, let final):
            usage = final
            message?.interrupted = false
            record.usageReported = true
            record.stopReason = reason.stored
            record.stopCategory = reason.category
        case .stopped(let reason):
            message?.interrupted = true
            record.stopReason = reason.rawValue
        case .failed(let error):
            message?.interrupted = !text.isEmpty
            record.errorKind = error.kind
            record.errorMessage = error.message
        }
        // Without final usage only the input side is known; the output so far is not reported, so it is not
        // recorded as a number.
        if !record.usageReported { usage.output = 0 }
        record.inputTokens = usage.input
        record.cachedInputTokens = usage.cacheRead
        record.cacheWriteTokens = usage.cacheWrite
        record.outputTokens = usage.output
        record.estimatedCost = ModelCatalog.cost(usage, catalog.resolve(record.modelID))
        if record.usageReported { calibrations[record.modelID] = nil }
        saves.markDirty()

        if case .reply = request.role {
            complete(id)
            return
        }
        record.rawOutput = text
        let outcome = message?.outcome(isStreaming: false) ?? record.outcome
        if case .declined = outcome {
            record.parseState = .unstructured
            complete(id)
            return
        }
        // A partial alignment is not read: it keeps its raw output, and the comparison keeps its earlier rows. Nor is
        // a partial draft or cell: code cut off part way must never be checked or run.
        switch request.role {
        case .alignment, .task:
            if outcome != .complete {
                record.parseState = .unstructured
                complete(id)
                return
            }
        default: break
        }
        request.state = .settling
        request.task = nil
        active[id] = request
        if shuttingDown {
            settleNow(id)
            return
        }
        let lenient = outcome.isPartial
        let role = request.role
        active[id]?.task = Task { [weak self] in
            let parsed: Parsed = switch role {
            case .referee: .referee(await OutputParsing.referee(text))
            case .alignment: .alignment(await OutputParsing.alignment(text))
            case .task(.formalization): .leanDraft(await OutputParsing.leanDraft(text))
            case .task(.scout(let basis)): .computeCell(await OutputParsing.computeCell(text, tools: basis.tools))
            case .reply, .attempt: .attempt(await OutputParsing.attempt(text, lenient: lenient))
            }
            self?.settle(id, parsed: parsed)
        }
    }

    /// Reads a settling request's output at once (quitting).
    private func settleNow(_ id: UUID) {
        guard let request = active[id] else { return }
        if case .alignment = request.role {
            settle(id, parsed: .alignment(AlignmentParser.parse(fetchRecord(id)?.rawOutput ?? "")))
            return
        }
        guard let message = fetchMessage(id) else { return }
        let text = message.request?.rawOutput ?? message.bodyLaTeX
        if case .referee = request.role {
            settle(id, parsed: .referee(RefereeParser.parse(text)))
        } else if case .task(.formalization) = request.role {
            settle(id, parsed: .leanDraft(TaskOutputParser.leanDraft(text)))
        } else if case .task(.scout(let basis)) = request.role {
            settle(id, parsed: .computeCell(TaskOutputParser.computeCell(text, tools: basis.tools)))
        } else {
            settle(id, parsed: .attempt(AttemptParser.parse(text, lenient: message.outcome(isStreaming: false).isPartial)))
        }
    }

    private func settle(_ id: UUID, parsed: Parsed) {
        // Gone when its problem was deleted meanwhile.
        guard let request = active[id], request.state == .settling else { return }
        if case .alignment(let basis) = request.role, case .alignment(let report) = parsed {
            if let record = fetchRecord(id) {
                apply(report, basis: basis, record: record, aligner: request.slot)
                saves.markDirty()
            }
            complete(id)
            return
        }
        if let message = fetchMessage(id) {
            switch (request.role, parsed) {
            case (.attempt, .attempt(let parse)):
                apply(parse, to: message, author: request.slot)
            case (.referee(let fanOutID, let attempts), .referee(let report)):
                apply(report, to: message, fanOutID: fanOutID, attempts: attempts, referee: request.slot)
            case (.task(let basis), _):
                apply(parsed, to: message, basis: basis)
            default:
                break
            }
            saves.markDirty()
        }
        complete(id)
    }

    /// The request is over: forget it, then let its fan-out move on.
    private func complete(_ id: UUID) {
        guard let request = active.removeValue(forKey: id) else { return }
        live[id] = nil
        updateStreamingBranches()
        switch request.role {
        case .reply, .alignment, .task: break
        case .attempt(let fanOutID): advance(fanOutID, .memberEnded(id))
        case .referee(let fanOutID, _): advance(fanOutID, .refereeEnded)
        }
    }

    private func advance(_ fanOutID: UUID, _ event: FanOutRun.Event) {
        guard var run = runs[fanOutID] else { return }
        let commands = run.handle(event)
        runs[fanOutID] = run.isSettled ? nil : run
        for command in commands {
            switch command {
            case .startMember(let id):
                startQueued(id, run: run)
            case .startReferee(let slotID):
                do {
                    try startReferee(fanOutID: fanOutID, slotID: slotID, run: run)
                } catch {
                    refereeNotices[fanOutID] = error.message
                    advance(fanOutID, .refereeEnded)
                }
            }
        }
    }

    /// An attempt's steps, each with a first revision by the model that wrote it (invariant 7). The overview becomes
    /// the message's text. Unreadable output stays as the raw text. Steps are written once: existing steps, and the
    /// reviews and revisions on them, are never replaced.
    private func apply(_ parse: AttemptParse, to message: Message, author: ModelSlotID) {
        guard let attempt = message.proofAttempt, let record = message.request else { return }
        switch parse {
        case .clean(let parsed), .partial(let parsed):
            let created = now()
            if (attempt.steps ?? []).isEmpty {
                attempt.steps = parsed.steps.enumerated().map { offset, parsedStep in
                    let step = Step(index: offset + 1, textLaTeX: parsedStep.text, establishes: parsedStep.establishes,
                                    confidence: parsedStep.confidence)
                    step.createdAt = created
                    let revision = StepRevision(author: .model(author), textLaTeX: parsedStep.text,
                                                establishes: parsedStep.establishes)
                    revision.createdAt = created
                    step.revisions = [revision]
                    // A model's citations start unverified (invariant 6); a person checks them on a click.
                    step.citations = parsedStep.citations.map { text in
                        let citation = Citation(rawText: text, status: .unverified, author: .model(author))
                        citation.createdAt = created
                        return citation
                    }
                    return step
                }
            }
            message.bodyLaTeX = parsed.overview
            if case .clean = parse {
                attempt.parsedCleanly = true
                record.parseState = .clean
            } else {
                record.parseState = .partial
            }
        case .unstructured:
            record.parseState = .unstructured
        }
    }

    /// The referee's verdicts, mapped failing closed. Its summary becomes the message's text.
    private func apply(_ report: RefereeReport?, to message: Message, fanOutID: UUID, attempts: [AttemptRef],
                       referee: ModelSlotID) {
        guard let record = message.request else { return }
        guard let report, let fanOut = fetchFanOut(fanOutID) else {
            record.parseState = .unstructured
            return
        }
        let created = now()
        let byMessage = Dictionary((fanOut.attempts ?? []).compactMap { attempt in attempt.message.map { ($0.stableID, attempt) } },
                                   uniquingKeysWith: { first, _ in first })
        let verdicts = VerdictMapper.map(report, attempts: attempts).map { draft in
            let verdict = RefereeVerdict(outcome: draft.outcome, gapStepIndices: draft.gapStepIndices, rationale: draft.rationale)
            verdict.createdAt = created
            // The referee judged the text it was sent when its request was made (rule 4).
            verdict.requestedAt = message.createdAt
            verdict.sawPartialAttempt = draft.sawPartialAttempt
            verdict.refereeSlotID = referee.rawValue
            verdict.messageID = message.stableID
            verdict.attempt = byMessage[draft.attemptMessageID]
            return verdict
        }
        fanOut.verdicts = (fanOut.verdicts ?? []) + verdicts
        message.bodyLaTeX = report.summary
        record.parseState = .clean
    }

    private func updateStreamingBranches() {
        let branches = Set(active.values.map(\.branchID))
        if branches != streamingBranchIDs { streamingBranchIDs = branches }
    }

    // MARK: Helpers

    private func snapshot(problem: Problem, branch: Branch) -> ProblemSnapshot {
        // The person using the app exists before anything is written in their name.
        _ = problems.me()
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        return ProblemSnapshot.make(problem: problem, branch: branch, notation: problems.notation(for: problem),
                                    people: people, liveMessageIDs: liveMessageIDs)
    }

    /// From the last ten requests to this model that reported their usage.
    private func calibration(for modelID: String) -> (calibration: TokenCalibration, samples: Int) {
        if let cached = calibrations[modelID] { return cached }
        var descriptor = FetchDescriptor<RequestRecord>(
            predicate: #Predicate { $0.usageReported && $0.modelID == modelID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 10
        let records = (try? context.fetch(descriptor)) ?? []
        let samples = records.map { (estimated: $0.estimatedInputTokens, actual: $0.usage.promptTotal) }
        let result = (TokenCalibration(samples: samples), samples.count)
        calibrations[modelID] = result
        return result
    }

    private func fetchRecord(_ id: UUID) -> RequestRecord? {
        context.first(RequestRecord.self, stableID: id)
    }

    private func attempt(_ id: UUID) -> ProofAttempt? {
        context.first(ProofAttempt.self, stableID: id)
    }

    private func fetchMessage(_ id: UUID) -> Message? {
        context.first(Message.self, stableID: id)
    }

    private func fetchFanOut(_ id: UUID) -> FanOut? {
        context.first(FanOut.self, stableID: id)
    }
}
