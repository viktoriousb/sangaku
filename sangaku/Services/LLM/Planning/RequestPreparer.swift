import Foundation

/// What preparing a request needs besides the snapshot. Values only, so planning is pure.
nonisolated struct PlannerEnvironment: Sendable {
    var catalog: ModelCatalog
    var prompts: PromptLibrary
    var builder: ContextBuilder
    var registry: ProviderRegistry
    /// Output reserved per request (`ThreadManager.maxOutputTokens`), capped by each model's own limit.
    var maxOutputTokens: Int
    /// How far each model's actual counts have run from the estimates, by model ID, with the number of samples.
    var calibrations: [String: (calibration: TokenCalibration, samples: Int)] = [:]
    /// Providers with no API key stored.
    var providersWithoutKey: Set<String> = []

    /// The provider a problem's first slot is created for.
    var defaultProviderID: String { registry.descriptors.first?.id ?? ProviderID.anthropic }

    func calibration(for modelID: String) -> (calibration: TokenCalibration, samples: Int) {
        calibrations[modelID] ?? (TokenCalibration(), 0)
    }

    func maxOutputTokens(for resolution: ModelResolution) -> Int {
        min(maxOutputTokens, resolution.info?.maxOutputTokens ?? maxOutputTokens)
    }
}

/// One request to prepare: who answers and in what capacity.
nonisolated struct RequestSpec: Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        /// A prose reply in the conversation.
        case reply
        /// A prover's structured attempt in a fan-out.
        case attempt(fanOut: UUID)
        /// The referee pass over a fan-out's attempts.
        case referee(fanOut: UUID)
        /// A referee-role slot aligning two attempts for Compare.
        case align(AlignmentBasis)
        /// A referee-role slot answering a question in prose (one row of a comparison): never a verdict.
        case refereeReply
    }

    var slot: ProblemSnapshot.SlotDigest
    var kind: Kind
    /// The new message, for a reply. Attempts answer the fan-out's stored prompt; a referee gets its instruction.
    var pending: String?
    var effort: ThinkingEffort
}

/// A request ready to go: what the model will see and exactly what is sent.
nonisolated struct PreparedRequest: Hashable, Sendable {
    let spec: RequestSpec
    let built: BuiltContext
    let request: ProviderRequest
    let resolution: ModelResolution
    let calibration: TokenCalibration
    let calibrated: Bool
}

/// Turns a slot and a purpose into a request. The one place where a slot's provider and model become a request's,
/// so routing, the provider policy and the prompt always agree with the slot.
nonisolated enum RequestPreparer {
    /// The referee's closing instruction, which also makes its context end with a turn of the person's.
    static func refereeInstruction(letters: [String]) -> String {
        let names = letters.map { "Model \($0)" }.joined(separator: ", ")
        return "Give your verdict on each attempt above (\(names)), identified by its letter."
    }

    static func prepare(_ spec: RequestSpec, snapshot: ProblemSnapshot,
                        env: PlannerEnvironment) throws(SendBlocker) -> PreparedRequest {
        let slot = spec.slot
        let providerName = env.registry.displayName(for: slot.providerID)
        // ContextBuilder refuses too (invariant 15); checking first gives the composer the provider's name.
        guard snapshot.allowedProviderIDs.contains(slot.providerID) else {
            throw .providerNotAllowed(providerID: slot.providerID, providerName: providerName)
        }
        let role: SlotRole
        let purpose: RequestPurpose
        let format: OutputFormat?
        var promptName: String?
        var pending = spec.pending
        switch spec.kind {
        case .reply:
            (role, purpose, format) = (.prover, .reply(slot: slot.id, fanOut: nil), nil)
        case .attempt(let fanOut):
            (role, purpose, format) = (.prover, .reply(slot: slot.id, fanOut: fanOut), .attempt)
        case .referee(let fanOut):
            let letters = snapshot.fanOut(fanOut).map { attemptLetters($0, in: snapshot) } ?? []
            (role, purpose, format) = (.referee, .referee(slot: slot.id, fanOut: fanOut), .refereeVerdicts(letters: letters))
            pending = pending ?? refereeInstruction(letters: letters)
        case .align(let basis):
            (role, purpose, format) = (.referee, .alignment(slot: slot.id, basis: basis), .alignment)
            promptName = "aligner"
        case .refereeReply:
            (role, purpose, format) = (.referee, .reply(slot: slot.id, fanOut: nil), nil)
            promptName = "referee-reply"
        }
        guard slot.role == role else { throw .slotCannotReceive(letter: slot.letter, role: slot.role) }
        let prompt = promptName.map { env.prompts.prompt(named: $0, role: role) }
            ?? env.prompts.prompt(for: role, structured: format != nil)
        guard let rolePrompt = prompt else { throw .noRolePrompt(role) }

        let resolution = env.catalog.resolve(slot.modelID)
        let maxOutput = env.maxOutputTokens(for: resolution)
        let (calibration, samples) = env.calibration(for: slot.modelID)
        let budget = resolution.info.map { Int(Double($0.contextWindow - maxOutput) / calibration.ratio) }
        let built: BuiltContext
        do {
            built = try env.builder.build(ContextInput(
                snapshot: snapshot, providerID: slot.providerID, purpose: purpose, rolePrompt: rolePrompt,
                pending: pending, inputBudget: budget, format: format))
        } catch {
            throw .context(error)
        }
        let request = ProviderRequest(built, modelID: slot.modelID, effort: spec.effort, maxOutputTokens: maxOutput)
        guard env.registry.provider(for: request) != nil else { throw .noProvider(slot.providerID) }
        return PreparedRequest(spec: spec, built: built, request: request, resolution: resolution,
                               calibration: calibration, calibrated: samples > 0)
    }

    /// The letters of the slots that wrote a fan-out's attempts, in attempt order.
    static func attemptLetters(_ fanOut: ProblemSnapshot.FanOutDigest, in snapshot: ProblemSnapshot) -> [String] {
        fanOut.attemptMessageIDs.compactMap { id in
            guard case .model(let slot) = snapshot.message(id)?.author else { return nil }
            return snapshot.slot(slot)?.letter
        }
    }
}
