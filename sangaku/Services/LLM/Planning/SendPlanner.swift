import Foundation

/// Why Send is not possible right now. The composer shows the message.
nonisolated enum SendBlocker: Error, Hashable, Sendable {
    case emptyMessage
    case providerNotAllowed(providerID: String, providerName: String)
    case missingKey(providerName: String)
    case busy
    case noRolePrompt(SlotRole)
    case noProvider(String)
    case context(ContextError)
    /// The problem has slots, but none is a prover.
    case noProver
    /// The slot's role cannot take this request (a referee asked for an attempt, a formalizer for a reply).
    case slotCannotReceive(letter: String, role: SlotRole)
    /// One recipient of a fan-out cannot be sent its context.
    case recipient(letter: String, ContextError)
    /// The slot a request was meant for no longer exists.
    case slotMissing
    /// Compare refuses the pair or the aligner.
    case compare(CompareError)

    var message: String {
        switch self {
        case .emptyMessage: "Write a message first."
        case .providerNotAllowed(_, let name): "This problem does not allow sending to \(name)."
        case .missingKey(let name): "No \(name) API key is stored."
        case .busy: "A request is still running on this branch."
        case .noRolePrompt(let role): "The \(role.rawValue) prompt is missing from the app bundle."
        case .noProvider(let id): "No provider named \(id) is available."
        case .context(let error): error.message
        case .noProver: "No model is a prover. Make a slot a prover, or add a model."
        case .slotCannotReceive(let letter, let role): "Model \(letter) is a \(role.rawValue) and cannot take this request."
        case .recipient(let letter, let error): "Model \(letter): \(error.message)"
        case .slotMissing: "The model slot this request was for no longer exists."
        case .compare(let error): error.message
        }
    }
}

/// What the composer shows before sending: a local estimate per model, so nothing leaves the Mac until Send.
nonisolated struct SendPlan: Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        /// One prover's prose reply.
        case reply
        /// Structured attempts from each prover, then perhaps a referee.
        case fanOut(FanOutVisibility)
    }

    nonisolated enum Cost: Hashable, Sendable {
        /// From "the stable part is read from the cache" to "it is written to the cache".
        case range(low: Double, high: Double)
        case single(Double)
        case unknown(modelID: String)

        var bounds: (low: Double, high: Double)? {
            switch self {
            case .range(let low, let high): (low, high)
            case .single(let cost): (cost, cost)
            case .unknown: nil
            }
        }
    }

    /// One prover's request.
    nonisolated struct Recipient: Hashable, Sendable {
        var letter: String
        /// Nil while the problem has no slot: the first send creates it.
        var slotID: UUID?
        var model: ModelResolution
        var fit: ContextFit?
        /// Calibrated estimates of the stable part and the whole prompt.
        var stableTokens: Int?
        var totalTokens: Int?
        var cost: Cost
        /// The most the output can cost: the output reserved for the request at the model's output price.
        var outputCeiling: Double?
        var calibrated = false
        var dropped: [DroppedContextItem] = []
        /// A later prover of a shared fan-out also sees the attempts before it, which are not counted yet.
        var seesEarlierAttempts = false
    }

    /// The referee: its input is the attempts, so only its output ceiling is known before sending.
    nonisolated struct Referee: Hashable, Sendable {
        var letter: String
        var model: ModelResolution
        var outputCeiling: Double?
    }

    var kind = Kind.reply
    var recipients: [Recipient] = []
    var referee: Referee?
    /// What the first recipient's context carries, for the context chips.
    var sections: [ContextSection] = []
    var conversationMessages = 0
    var dropped: [DroppedContextItem] = []
    var blocker: SendBlocker?

    var providerID: String
    var providerName: String

    /// "Send to A", "Send to A, B, then C".
    var sendLabel: String {
        let to = recipients.map(\.letter).joined(separator: ", ")
        return "Send to \(to.isEmpty ? "A" : to)" + (referee.map { ", then \($0.letter)" } ?? "")
    }

    /// The input cost of every recipient, or unknown when any price is.
    var inputCost: Cost {
        var low = 0.0, high = 0.0
        for recipient in recipients {
            guard let bounds = recipient.cost.bounds else { return recipient.cost }
            low += bounds.low
            high += bounds.high
        }
        return low == high ? .single(low) : .range(low: low, high: high)
    }

    /// The most every request's output can cost together, the referee's included; nil when any price is unknown.
    var outputCeiling: Double? {
        let ceilings = recipients.map(\.outputCeiling) + (referee.map { [$0.outputCeiling] } ?? [])
        guard !ceilings.contains(nil) else { return nil }
        return ceilings.compactMap { $0 }.reduce(0, +)
    }
}

/// A send whose every context was built and checked. Only `SendPlanner` makes one, so nothing is written to the
/// store for a send that any recipient would refuse.
nonisolated struct ReadySend: Sendable {
    nonisolated struct Member: Sendable {
        let messageID: UUID
        let slot: ProblemSnapshot.SlotDigest
        let createdAt: Date
        /// Built against the fan-out as it will be stored. A later prover of a shared fan-out is rebuilt when its
        /// turn comes, so it sees the attempts before it; this one only checked that it can be sent.
        let prepared: PreparedRequest
    }

    let kind: SendPlan.Kind
    let text: String
    let promptID: UUID
    let promptCreatedAt: Date
    /// For a fan-out.
    let fanOutID: UUID?
    let referee: ProblemSnapshot.SlotDigest?
    let members: [Member]
    /// The slot a problem's first send creates.
    let newSlot: ProblemSnapshot.SlotDigest?
    let effort: ThinkingEffort
    /// The messages the prompt is about, for a question about attempts: a later independent fan-out never sees it.
    let promptDerivedFromIDs: [UUID]
    /// The kind of a prose reply: a prover's, or a referee's answer to a question.
    let replyKind: MessageKind

    fileprivate init(kind: SendPlan.Kind, text: String, promptID: UUID, promptCreatedAt: Date, fanOutID: UUID?,
                     referee: ProblemSnapshot.SlotDigest?, members: [Member], newSlot: ProblemSnapshot.SlotDigest?,
                     effort: ThinkingEffort, promptDerivedFromIDs: [UUID] = [], replyKind: MessageKind = .reply) {
        self.promptDerivedFromIDs = promptDerivedFromIDs
        self.replyKind = replyKind
        self.kind = kind
        self.text = text
        self.promptID = promptID
        self.promptCreatedAt = promptCreatedAt
        self.fanOutID = fanOutID
        self.referee = referee
        self.members = members
        self.newSlot = newSlot
        self.effort = effort
    }
}

/// What a send is asked to do, as values.
nonisolated struct SendRequest: Sendable {
    var snapshot: ProblemSnapshot
    var selection: SendSelection
    var text: String
    var effort: ThinkingEffort
    /// Something is still running on the branch.
    var busy: Bool
    var now: Date
}

/// Plans and checks a send. Pure: the estimate the composer shows and the requests Send makes come from the same
/// preparation, against the same snapshot.
nonisolated enum SendPlanner {
    /// The estimate, with the first reason Send is not possible. Estimates are made even for an empty draft, a
    /// busy branch or a missing key, so the composer can show them.
    static func plan(_ request: SendRequest, env: PlannerEnvironment) -> SendPlan {
        let selection = resolve(request, env: env)
        let providerID = selection.provers.first?.providerID ?? env.defaultProviderID
        var plan = SendPlan(providerID: providerID, providerName: env.registry.displayName(for: providerID))
        guard !selection.provers.isEmpty else {
            plan.blocker = .noProver
            return plan
        }
        plan.kind = selection.isFanOut ? .fanOut(selection.visibility) : .reply
        plan.recipients = selection.provers.map { slot in
            let resolution = env.catalog.resolve(slot.modelID)
            return SendPlan.Recipient(letter: slot.letter, slotID: request.snapshot.slot(slot.id)?.id.rawValue,
                                      model: resolution, cost: .unknown(modelID: resolution.modelID),
                                      outputCeiling: outputCeiling(resolution, env: env))
        }
        plan.referee = selection.referee.map { slot in
            let resolution = env.catalog.resolve(slot.modelID)
            return SendPlan.Referee(letter: slot.letter, model: resolution, outputCeiling: outputCeiling(resolution, env: env))
        }
        // An empty draft still gets an estimate of everything else.
        var text = request.text
        if selection.isFanOut && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = "…" }
        let prepared: [PreparedRequest]
        do {
            prepared = try prepareAll(selection, text: text, request: request, env: env).members.map(\.prepared)
            if let referee = selection.referee { try checkReferee(referee, snapshot: request.snapshot, env: env) }
        } catch {
            plan.blocker = error
            return plan
        }
        for (index, member) in prepared.enumerated() {
            plan.recipients[index] = estimate(plan.recipients[index], member,
                                              seesEarlierAttempts: index > 0 && selection.visibility == .shared)
        }
        if let first = prepared.first {
            plan.sections = first.built.stable
            plan.conversationMessages = first.built.includedMessageIDs.count
            plan.dropped = first.built.dropped
        }
        plan.blocker = softBlocker(request, selection: selection, env: env)
        return plan
    }

    /// Everything needed to send, or the first reason not to. Nothing is written until this succeeds.
    static func ready(_ request: SendRequest, env: PlannerEnvironment) throws(SendBlocker) -> ReadySend {
        let selection = resolve(request, env: env)
        guard !selection.provers.isEmpty else { throw .noProver }
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .emptyMessage }
        guard !request.busy else { throw .busy }
        for slot in selection.provers + (selection.referee.map { [$0] } ?? []) {
            try checkProvider(of: slot, snapshot: request.snapshot, env: env)
        }
        if let referee = selection.referee { try checkReferee(referee, snapshot: request.snapshot, env: env) }
        return try prepareAll(selection, text: text, request: request, env: env)
    }

    /// One question to one slot from outside the composer (repairing a step, or refereeing one row of a comparison):
    /// a prose exchange, with the same checks as a send. A referee-role slot answers with its own prompt, never with
    /// a verdict.
    static func readyQuestion(_ text: String, to slot: ProblemSnapshot.SlotDigest, about linked: [UUID],
                              snapshot: ProblemSnapshot, effort: ThinkingEffort, busy: Bool, now: Date,
                              env: PlannerEnvironment) throws(SendBlocker) -> ReadySend {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .emptyMessage }
        guard !busy else { throw .busy }
        try checkProvider(of: slot, snapshot: snapshot, env: env)
        let isReferee = slot.role == .referee
        let prepared = try RequestPreparer.prepare(
            RequestSpec(slot: slot, kind: isReferee ? .refereeReply : .reply, pending: text, effort: effort),
            snapshot: snapshot, env: env)
        let member = ReadySend.Member(messageID: UUID(), slot: slot, createdAt: now.addingTimeInterval(0.001),
                                      prepared: prepared)
        return ReadySend(kind: .reply, text: text, promptID: UUID(), promptCreatedAt: now, fanOutID: nil, referee: nil,
                         members: [member], newSlot: nil, effort: effort, promptDerivedFromIDs: linked,
                         replyKind: isReferee ? .refereeReply : .reply)
    }

    // MARK: Preparation

    /// The selection, with the slot a problem's first send creates when it has none yet.
    private static func resolve(_ request: SendRequest, env: PlannerEnvironment) -> ResolvedSelection {
        guard request.snapshot.slots.isEmpty else { return request.selection.resolved(request.snapshot.slots) }
        let providerID = env.defaultProviderID
        let modelID = env.catalog.defaultModel(for: providerID)?.id ?? ""
        let first = ProblemSnapshot.SlotDigest(id: ModelSlotID(UUID()), letter: "A", providerID: providerID,
                                               modelID: modelID, role: .prover)
        return ResolvedSelection(provers: [first], referee: nil, visibility: request.selection.visibility)
    }

    private static func prepareAll(_ selection: ResolvedSelection, text: String, request: SendRequest,
                                   env: PlannerEnvironment) throws(SendBlocker) -> ReadySend {
        let snapshot = request.snapshot
        let newSlot = snapshot.slots.isEmpty ? selection.provers.first : nil
        var withNewSlot = snapshot
        if let newSlot { withNewSlot.slots.append(newSlot) }
        let promptID = UUID()
        guard selection.isFanOut else {
            let slot = selection.provers[0]
            guard !slot.modelID.isEmpty else { throw .noProvider(slot.providerID) }
            let prepared = try RequestPreparer.prepare(
                RequestSpec(slot: slot, kind: .reply, pending: text, effort: request.effort), snapshot: withNewSlot, env: env)
            let member = ReadySend.Member(messageID: UUID(), slot: slot, createdAt: request.now.addingTimeInterval(0.001),
                                          prepared: prepared)
            return ReadySend(kind: .reply, text: text, promptID: promptID, promptCreatedAt: request.now, fanOutID: nil,
                             referee: nil, members: [member], newSlot: newSlot, effort: request.effort)
        }

        let fanOutID = UUID()
        let attempts = selection.provers.enumerated().map { index, slot in
            ProblemSnapshot.PendingAttempt(messageID: UUID(), slot: slot.id,
                                           createdAt: request.now.addingTimeInterval(0.001 * Double(index + 1)))
        }
        let pending = withNewSlot.addingFanOut(
            id: fanOutID, visibility: selection.visibility, refereeSlotID: selection.referee?.id.rawValue,
            promptID: promptID, promptText: text, promptAuthor: snapshot.meID.map { .human(PersonID($0)) },
            promptCreatedAt: request.now, attempts: attempts)
        var members: [ReadySend.Member] = []
        for (slot, attempt) in zip(selection.provers, attempts) {
            let prepared: PreparedRequest
            do {
                prepared = try RequestPreparer.prepare(
                    RequestSpec(slot: slot, kind: .attempt(fanOut: fanOutID), effort: request.effort),
                    snapshot: pending, env: env)
            } catch {
                if case .context(let context) = error { throw .recipient(letter: slot.letter, context) }
                throw error
            }
            members.append(ReadySend.Member(messageID: attempt.messageID, slot: slot, createdAt: attempt.createdAt,
                                            prepared: prepared))
        }
        return ReadySend(kind: .fanOut(selection.visibility), text: text, promptID: promptID,
                         promptCreatedAt: request.now, fanOutID: fanOutID, referee: selection.referee,
                         members: members, newSlot: newSlot, effort: request.effort)
    }

    /// The problem allows the slot's provider (invariant 15) and a key is stored for it.
    static func checkProvider(of slot: ProblemSnapshot.SlotDigest, snapshot: ProblemSnapshot,
                              env: PlannerEnvironment) throws(SendBlocker) {
        try checkAllowed(slot, snapshot: snapshot, env: env)
        guard !env.providersWithoutKey.contains(slot.providerID) else {
            throw .missingKey(providerName: env.registry.displayName(for: slot.providerID))
        }
    }

    private static func checkAllowed(_ slot: ProblemSnapshot.SlotDigest, snapshot: ProblemSnapshot,
                                     env: PlannerEnvironment) throws(SendBlocker) {
        guard snapshot.allowedProviderIDs.contains(slot.providerID) else {
            throw .providerNotAllowed(providerID: slot.providerID, providerName: env.registry.displayName(for: slot.providerID))
        }
    }

    /// The referee cannot be built before the attempts exist; what can be checked now is. A missing key is only a
    /// soft blocker while planning, so the estimate still shows.
    private static func checkReferee(_ slot: ProblemSnapshot.SlotDigest, snapshot: ProblemSnapshot,
                                     env: PlannerEnvironment) throws(SendBlocker) {
        try checkAllowed(slot, snapshot: snapshot, env: env)
        guard env.prompts.prompt(for: .referee, structured: true) != nil else { throw .noRolePrompt(.referee) }
        guard env.registry.descriptors.contains(where: { $0.id == slot.providerID }) else { throw .noProvider(slot.providerID) }
    }

    // MARK: Estimates

    /// The estimate for one request made outside a send (an alignment), as the composer shows one recipient's.
    static func estimate(_ prepared: PreparedRequest, letter: String, env: PlannerEnvironment) -> SendPlan.Recipient {
        let recipient = SendPlan.Recipient(letter: letter, slotID: prepared.spec.slot.id.rawValue,
                                           model: prepared.resolution, cost: .unknown(modelID: prepared.spec.slot.modelID),
                                           outputCeiling: outputCeiling(prepared.resolution, env: env))
        return estimate(recipient, prepared, seesEarlierAttempts: false)
    }

    private static func estimate(_ recipient: SendPlan.Recipient, _ prepared: PreparedRequest,
                                 seesEarlierAttempts: Bool) -> SendPlan.Recipient {
        var recipient = recipient
        let built = prepared.built
        let calibration = prepared.calibration
        let stable = calibration.apply(built.stableTokens)
        let rest = calibration.apply(built.conversationTokens + built.formatTokens)
        recipient.fit = built.fit
        recipient.dropped = built.dropped
        recipient.stableTokens = stable
        recipient.totalTokens = stable + rest
        recipient.calibrated = prepared.calibrated
        recipient.seesEarlierAttempts = seesEarlierAttempts
        if let info = prepared.resolution.info {
            if stable >= info.minimumCacheablePrefix {
                recipient.cost = .range(low: ModelCatalog.cost(TokenUsage(input: rest, cacheRead: stable), prepared.resolution) ?? 0,
                                        high: ModelCatalog.cost(TokenUsage(input: rest, cacheWrite: stable), prepared.resolution) ?? 0)
            } else {
                recipient.cost = .single(ModelCatalog.cost(TokenUsage(input: stable + rest), prepared.resolution) ?? 0)
            }
        }
        return recipient
    }

    private static func outputCeiling(_ resolution: ModelResolution, env: PlannerEnvironment) -> Double? {
        resolution.info.flatMap { info in
            ModelCatalog.cost(TokenUsage(output: env.maxOutputTokens(for: resolution)), .known(info))
        }
    }

    /// Reasons Send is not possible that still leave the estimate meaningful.
    private static func softBlocker(_ request: SendRequest, selection: ResolvedSelection,
                                    env: PlannerEnvironment) -> SendBlocker? {
        if request.busy { return .busy }
        let providers = selection.provers.map(\.providerID) + (selection.referee.map { [$0.providerID] } ?? [])
        if let missing = providers.first(where: env.providersWithoutKey.contains) {
            return .missingKey(providerName: env.registry.displayName(for: missing))
        }
        if request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyMessage }
        return nil
    }
}
