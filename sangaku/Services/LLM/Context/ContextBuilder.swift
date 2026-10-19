import Foundation

/// What a request is for.
nonisolated enum RequestPurpose: Hashable, Sendable {
    /// An answer from `slot` (nil while the problem has no slot yet, for an estimate). With `fanOut`, the
    /// answer is the slot's attempt in that fan-out.
    case reply(slot: ModelSlotID?, fanOut: UUID?)
    /// The referee pass over a fan-out's attempts (Milestone 3).
    case referee(slot: ModelSlotID, fanOut: UUID)

    var slot: ModelSlotID? {
        switch self {
        case .reply(let slot, _): slot
        case .referee(let slot, _): slot
        }
    }
}

nonisolated struct ContextInput: Sendable {
    var snapshot: ProblemSnapshot
    var providerID: String
    var purpose: RequestPurpose
    var rolePrompt: RolePrompt
    /// The new message, not yet stored. Nil when answering the conversation as it stands.
    var pending: String?
    /// The most input the model can take once its output is reserved. Nil when the model's window is unknown:
    /// then nothing is dropped.
    var inputBudget: Int?
    /// The structured output the request asks for; its schema counts toward the input.
    var format: OutputFormat? = nil
}

nonisolated enum ContextError: Error, Hashable, Sendable {
    /// The problem does not allow this provider (invariant 15).
    case providerNotAllowed(String)
    /// The referee must wait until every attempt has finished or been stopped (invariant 4).
    case attemptsUnfinished([UUID])
    /// The problem, notation, refuted claims and the new message alone exceed the model's window.
    case essentialsDoNotFit(needed: Int, budget: Int)
    /// The conversation ends with the model's own reply and there is no new message.
    case nothingToAnswer
    /// The purpose names a fan-out, or a fan-out names an attempt, that is not on this branch. Refused rather
    /// than built without the fan-out's rules (invariant 4).
    case fanOutNotOnBranch(UUID)

    var message: String {
        switch self {
        case .providerNotAllowed(let provider):
            "This problem does not allow sending to \(provider)."
        case .attemptsUnfinished(let ids):
            "The referee waits until every attempt has finished or been stopped (\(ids.count) still running)."
        case .essentialsDoNotFit(let needed, let budget):
            "The problem, notation, refuted claims and your message need about \(needed) tokens, more than the model's \(budget)."
        case .nothingToAnswer:
            "There is no new message to answer."
        case .fanOutNotOnBranch:
            "The fan-out this request belongs to is not on this branch."
        }
    }
}

nonisolated enum ContextSectionKind: String, CaseIterable, Hashable, Sendable {
    case rolePrompt, problem, notation, adoptedLemmas, deadEnds, refutedClaims
}

/// One block of the stable part.
nonisolated struct ContextSection: Hashable, Sendable {
    var kind: ContextSectionKind
    var title: String
    var text: String
    var itemCount: Int
    var tokens: Int
}

nonisolated struct ContextTurn: Hashable, Sendable {
    nonisolated enum Role: String, Hashable, Sendable {
        case user, assistant
    }

    var role: Role
    var blocks: [String]
    var messageIDs: [UUID]
}

nonisolated enum ContextFit: Hashable, Sendable {
    case fits(used: Int, budget: Int)
    case dropped(count: Int, used: Int, budget: Int)
    case unknownWindow(used: Int)
}

/// Exactly what one model will see. Only `ContextBuilder` makes one, after checking the provider policy, and a
/// `ProviderRequest` can only be made from one.
nonisolated struct BuiltContext: Hashable, Sendable {
    let providerID: String
    let promptVersion: String
    /// The stable part, in order. The provider may cache it; the last section ends it.
    let stable: [ContextSection]
    /// The conversation; the last turn is always the user's.
    let turns: [ContextTurn]
    /// What was left out to fit the window, in the order it was dropped (invariant 5).
    let dropped: [DroppedContextItem]
    let includedMessageIDs: [UUID]
    /// Messages kept from a model because an independent fan-out keeps its attempts apart (invariant 4).
    let withheldMessageIDs: [UUID]
    /// Attempts the referee sees that were stopped before they finished.
    let partialAttemptIDs: [UUID]
    let stableTokens: Int
    let conversationTokens: Int
    /// The structured output asked for, and the tokens its schema adds.
    let format: OutputFormat?
    let formatTokens: Int
    let fit: ContextFit
    /// The text of every block, in order, with the cache breakpoint marked: what View context shows.
    let transcript: String

    var totalTokens: Int { stableTokens + conversationTokens + formatTokens }

    fileprivate init(providerID: String, promptVersion: String, stable: [ContextSection], turns: [ContextTurn],
                     dropped: [DroppedContextItem], includedMessageIDs: [UUID], withheldMessageIDs: [UUID],
                     partialAttemptIDs: [UUID], stableTokens: Int, conversationTokens: Int, format: OutputFormat?,
                     formatTokens: Int, fit: ContextFit, transcript: String) {
        self.providerID = providerID
        self.promptVersion = promptVersion
        self.stable = stable
        self.turns = turns
        self.dropped = dropped
        self.includedMessageIDs = includedMessageIDs
        self.withheldMessageIDs = withheldMessageIDs
        self.partialAttemptIDs = partialAttemptIDs
        self.stableTokens = stableTokens
        self.conversationTokens = conversationTokens
        self.format = format
        self.formatTokens = formatTokens
        self.fit = fit
        self.transcript = transcript
    }
}

/// Builds exactly what a model sees for one request. Pure: the same input gives the same context.
///
/// The stable part comes first (role prompt, problem, notation, adopted lemmas, dead ends, refuted claims), one
/// block per section, so provider prompt caching applies; the conversation follows. Every section is always
/// present, "(none yet)" when empty, so the prefix keeps its shape.
nonisolated struct ContextBuilder: Sendable {
    /// Estimates run high by design, and a fit check leaves this much on top as a margin.
    static let fitMargin = 1.1
    static let droppedConversationNotice = "[Earlier messages were left out to fit the context window.]"
    static let conversationStartNotice = "[The discussion on this branch begins here.]"

    var estimator = TokenEstimator()

    func build(_ input: ContextInput) throws(ContextError) -> BuiltContext {
        let snapshot = input.snapshot
        // Invariant 15, before anything else.
        guard snapshot.allowedProviderIDs.contains(input.providerID) else {
            throw .providerNotAllowed(input.providerID)
        }

        let recipient = input.purpose.slot
        var withheld: Set<UUID> = []
        var refereeAttempts: Set<UUID> = []
        var partialAttempts: [UUID] = []
        /// The message that started the fan-out this request belongs to: it and everything after it are what is
        /// being answered, and are never dropped.
        var fanOutRequestID: UUID?
        switch input.purpose {
        case .reply(let slot, let fanOutID?):
            guard let fanOut = snapshot.fanOut(fanOutID) else { throw .fanOutNotOnBranch(fanOutID) }
            if fanOut.visibility == .independent {
                withheld = Self.independentExclusions(fanOut, recipient: slot, in: snapshot)
            }
            fanOutRequestID = fanOut.requestMessageID
        case .reply(_, nil):
            break
        case .referee(_, let fanOutID):
            guard let fanOut = snapshot.fanOut(fanOutID) else { throw .fanOutNotOnBranch(fanOutID) }
            let attempts = try fanOut.attemptMessageIDs.map { id throws(ContextError) in
                guard let attempt = snapshot.message(id) else { throw .fanOutNotOnBranch(fanOutID) }
                return attempt
            }
            let running = attempts.filter { $0.outcome == .streaming }.map(\.id)
            guard running.isEmpty else { throw .attemptsUnfinished(running) }
            refereeAttempts = Set(attempts.map(\.id))
            partialAttempts = attempts.filter(\.outcome.isPartial).map(\.id)
            // The referee sees the branch as it stood when the last attempt was written: nothing said since, so a
            // second referee judges afresh, without an earlier referee's verdicts or anyone's later account of them.
            if let last = attempts.map(\.createdAt).max() {
                for message in snapshot.messages where message.createdAt > last { withheld.insert(message.id) }
            }
            fanOutRequestID = fanOut.requestMessageID
        }

        // The conversation as units: one per message that has something to say, and every attempt the
        // referee must hear about.
        var units: [Unit] = []
        for message in snapshot.messages where !withheld.contains(message.id) {
            let unit = refereeAttempts.contains(message.id)
                ? refereeUnit(for: message, snapshot: snapshot)
                : unit(for: message, recipient: recipient, snapshot: snapshot)
            if let unit { units.append(unit) }
        }
        if let pending = input.pending {
            units.append(Unit(messageID: nil, role: .user, text: pending, tokens: estimator.blockTokens(pending),
                              dropTitle: "Your new message"))
        } else if units.last?.role != .user {
            throw .nothingToAnswer
        }

        // Exchanges: a user unit and the replies after it. The last one (the message being answered) is never
        // dropped. For a fan-out it runs from the fan-out's request, so the prompt and the attempts a shared
        // prover or the referee answer stay together.
        var exchanges: [[Unit]] = []
        var answered: [Unit] = []
        let answeredStart = fanOutRequestID.flatMap { id in units.firstIndex { $0.messageID == id } }
        for (index, unit) in units.enumerated() {
            if let answeredStart, index >= answeredStart {
                answered.append(unit)
            } else if unit.role == .user || exchanges.isEmpty {
                exchanges.append([unit])
            } else {
                exchanges[exchanges.count - 1].append(unit)
            }
        }
        if answeredStart == nil { answered = exchanges.removeLast() }

        let formatTokens = input.format.map { estimator.blockTokens($0.schemaJSON) } ?? 0
        // The graph's order, so the cached prefix is the same on every send.
        var lemmas = snapshot.adoptedLemmas.sorted {
            StatementGraphState.precedes(($0.createdAt, $0.label, $0.id), ($1.createdAt, $1.label, $1.id))
        }
        var deadEnds = snapshot.deadEnds.sorted { $0.createdAt < $1.createdAt }
        var omittedLemmas = 0
        var omittedDeadEnds = 0
        var dropped: [DroppedContextItem] = []
        var droppedConversation = false

        func sections() -> [ContextSection] {
            stableSections(input: input, lemmas: lemmas, omittedLemmas: omittedLemmas,
                           deadEnds: deadEnds, omittedDeadEnds: omittedDeadEnds)
        }
        func conversationTokens() -> Int {
            exchanges.joined().map(\.tokens).reduce(0, +) + answered.map(\.tokens).reduce(0, +)
                + (droppedConversation ? estimator.blockTokens(Self.droppedConversationNotice) : 0)
        }
        func total() -> Int { sections().map(\.tokens).reduce(0, +) + conversationTokens() + formatTokens }
        func fits(_ budget: Int) -> Bool { Double(total()) * Self.fitMargin <= Double(budget) }

        // Invariant 5: drop in a defined order, record every drop, never cut inside an item.
        if let budget = input.inputBudget {
            // 1. Older exchanges, oldest first; the latest exchange stays for now.
            while !fits(budget), exchanges.count > 1 {
                dropped += exchanges.removeFirst().map(\.droppedItem)
                droppedConversation = true
            }
            // 2. Dead ends, oldest first.
            while !fits(budget), !deadEnds.isEmpty {
                let deadEnd = deadEnds.removeFirst()
                omittedDeadEnds += 1
                dropped.append(DroppedContextItem(kind: "Dead end", title: deadEnd.name,
                                                  tokens: estimator.tokens(Self.deadEndLine(deadEnd))))
            }
            // 3. Adopted lemmas, oldest first.
            while !fits(budget), !lemmas.isEmpty {
                let lemma = lemmas.removeFirst()
                omittedLemmas += 1
                dropped.append(DroppedContextItem(kind: "Adopted lemma", title: lemma.label,
                                                  tokens: estimator.tokens(Self.lemmaLine(lemma))))
            }
            // 4. The latest exchange.
            while !fits(budget), !exchanges.isEmpty {
                dropped += exchanges.removeFirst().map(\.droppedItem)
                droppedConversation = true
            }
            // Role prompt, problem, notation, refuted claims and the message being answered are never dropped.
            guard fits(budget) else { throw .essentialsDoNotFit(needed: total(), budget: budget) }
        }

        let stable = sections()
        let kept = Array(exchanges.joined()) + answered
        let turns = Self.turns(from: kept, droppedConversation: droppedConversation)
        let stableTokens = stable.map(\.tokens).reduce(0, +)
        let conversation = conversationTokens()
        let used = stableTokens + conversation + formatTokens
        let fit: ContextFit = if let budget = input.inputBudget {
            dropped.isEmpty ? .fits(used: used, budget: budget) : .dropped(count: dropped.count, used: used, budget: budget)
        } else {
            .unknownWindow(used: used)
        }
        return BuiltContext(
            providerID: input.providerID, promptVersion: input.rolePrompt.versionTag, stable: stable, turns: turns,
            dropped: dropped, includedMessageIDs: kept.compactMap(\.messageID),
            withheldMessageIDs: snapshot.messages.map(\.id).filter(withheld.contains),
            partialAttemptIDs: partialAttempts, stableTokens: stableTokens, conversationTokens: conversation,
            format: input.format, formatTokens: formatTokens, fit: fit,
            transcript: Self.transcript(stable: stable, turns: turns))
    }

    // MARK: Invariant 4

    /// For `recipient`'s attempt in an independent fan-out: the other provers' attempts, every message derived
    /// from them (following `derivedFromIDs` to a fixpoint), and, failing closed, every message another model
    /// wrote after the fan-out's request, linked or not.
    static func independentExclusions(_ fanOut: ProblemSnapshot.FanOutDigest, recipient: ModelSlotID?,
                                      in snapshot: ProblemSnapshot) -> Set<UUID> {
        var excluded = Set(fanOut.attemptMessageIDs.filter { id in
            guard let recipient else { return true }
            return snapshot.message(id)?.author != .model(recipient)
        })
        var changed = true
        while changed {
            changed = false
            for message in snapshot.messages where !excluded.contains(message.id) {
                if message.derivedFromIDs.contains(where: excluded.contains) {
                    excluded.insert(message.id)
                    changed = true
                }
            }
        }
        if let requestID = fanOut.requestMessageID, let request = snapshot.message(requestID) {
            for message in snapshot.messages where message.createdAt > request.createdAt {
                if case .model(let author) = message.author, author != recipient { excluded.insert(message.id) }
            }
        }
        return excluded
    }

    // MARK: Conversation

    private struct Unit {
        var messageID: UUID?
        var role: ContextTurn.Role
        var text: String
        var tokens: Int
        var dropTitle: String

        var droppedItem: DroppedContextItem {
            DroppedContextItem(kind: "Message", title: dropTitle, tokens: tokens)
        }
    }

    private func unit(for message: ProblemSnapshot.MessageDigest, recipient: ModelSlotID?,
                      snapshot: ProblemSnapshot) -> Unit? {
        switch message.outcome {
        case .streaming, .declined: return nil
        default: break
        }
        let isOwn = recipient.map { message.author == .model($0) } ?? false
        var parts: [String] = []
        if !isOwn, let label = Self.label(for: message, in: snapshot) { parts.append(label) }
        let content = Self.content(of: message, in: snapshot)
        guard !content.isEmpty else { return nil }
        parts += content
        switch message.outcome {
        case .interrupted:
            parts.append(isOwn ? "[This reply was stopped before it finished.]" : "[This message was stopped before it finished.]")
        case .cutOff:
            parts.append("[This reply was cut off at the output limit.]")
        case .endedEarly(let reason):
            parts.append("[This reply ended early (\(reason)) and may be incomplete.]")
        case .failed:
            parts.append("[This reply ended with an error before it finished.]")
        case .streaming, .complete, .declined:
            break
        }
        return makeUnit(message, role: isOwn ? .assistant : .user, parts: parts, snapshot: snapshot)
    }

    /// An attempt as the referee sees it: always present, even with no text, and marked when it is partial or
    /// was declined (invariant 4). "To judge" sets it apart from attempts of earlier fan-outs by the same letters.
    private func refereeUnit(for message: ProblemSnapshot.MessageDigest, snapshot: ProblemSnapshot) -> Unit {
        let author = Self.authorName(message.author, in: snapshot)
        let header = switch message.outcome {
        case .interrupted: "[PARTIAL attempt by \(author), to judge: stopped before finishing]"
        case .cutOff: "[PARTIAL attempt by \(author), to judge: cut off at the output limit]"
        case .endedEarly(let reason): "[PARTIAL attempt by \(author), to judge: ended early (\(reason))]"
        case .failed: "[PARTIAL attempt by \(author), to judge: ended with an error before finishing]"
        case .declined: "[Attempt by \(author), to judge: declined by the provider; there is no attempt]"
        case .streaming, .complete: "[Attempt by \(author), to judge]"
        }
        let content = Self.content(of: message, in: snapshot)
        let noText: [String] = if case .declined = message.outcome { [] } else { ["(no text arrived)"] }
        return makeUnit(message, role: .user, parts: [header] + (content.isEmpty ? noText : content), snapshot: snapshot)
    }

    /// A message's body, its steps and, for a referee, its verdicts. A step a person revised says so.
    private static func content(of message: ProblemSnapshot.MessageDigest, in snapshot: ProblemSnapshot) -> [String] {
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return (body.isEmpty ? [] : [body])
            + message.steps.map { step in
                let revised = step.revisedBy.map { "; revised by \(revisorName($0, in: snapshot))" } ?? ""
                return "Step \(step.index) (establishes: \(step.establishes); confidence: \(step.confidence.rawValue)\(revised)): \(step.textLaTeX)"
            }
            + message.verdicts.map(verdictLine)
    }

    /// "the researcher" for the person using the app: in a prompt "you" is the model. Others by name.
    private static func revisorName(_ author: Author, in snapshot: ProblemSnapshot) -> String {
        if case .human(let person) = author, person.rawValue == snapshot.meID { return "the researcher" }
        return authorName(author, in: snapshot)
    }

    static func verdictLine(_ verdict: ProblemSnapshot.VerdictDigest) -> String {
        let outcome = switch verdict.outcome {
        case .complete: "complete"
        case .gap where verdict.gapStepIndices.isEmpty: "gap"
        case .gap: "gap at step\(verdict.gapStepIndices.count == 1 ? "" : "s") "
            + verdict.gapStepIndices.map(String.init).joined(separator: ", ")
        }
        let partial = verdict.sawPartialAttempt ? " (the attempt was partial)" : ""
        return "Verdict on Model \(verdict.attemptLetter)'s attempt\(partial): \(outcome). \(verdict.rationale)"
    }

    private func makeUnit(_ message: ProblemSnapshot.MessageDigest, role: ContextTurn.Role, parts: [String],
                          snapshot: ProblemSnapshot) -> Unit {
        let text = parts.joined(separator: "\n")
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = body.isEmpty ? (message.steps.first?.textLaTeX ?? "") : body
        let title = "\(Self.authorName(message.author, in: snapshot)) · \(String(preview.prefix(60)))"
        return Unit(messageID: message.id, role: role, text: text, tokens: estimator.blockTokens(text), dropTitle: title)
    }

    /// How a message by someone other than the recipient is introduced. The person using the app needs no label.
    private static func label(for message: ProblemSnapshot.MessageDigest, in snapshot: ProblemSnapshot) -> String? {
        switch message.author {
        case .human(let person):
            return person.rawValue == snapshot.meID ? nil : "[\(snapshot.people[person.rawValue] ?? "A collaborator")]"
        case .model(let slotID):
            guard let slot = snapshot.slot(slotID) else { return "[A model]" }
            // The role the message was written in, not the slot's role now: editing a slot never relabels history.
            return switch message.kind {
            case .referee: "[Referee \(slot.letter)]"
            case .compute: "[Computation cell by \(slot.letter)]"
            case .attempt: "[Attempt by Model \(slot.letter)]"
            default: "[Model \(slot.letter)" + (message.kind.authoringRole.map { " · \($0.rawValue)" } ?? "") + "]"
            }
        case nil:
            return message.kind == .system ? "[Note]" : "[Unknown author]"
        }
    }

    private static func authorName(_ author: Author?, in snapshot: ProblemSnapshot) -> String {
        switch author {
        case .human(let person): snapshot.people[person.rawValue] ?? "A person"
        case .model(let slotID): snapshot.slot(slotID).map { "Model \($0.letter)" } ?? "A model"
        case nil: "Unknown author"
        }
    }

    /// Merges adjacent units of one role into a turn with several blocks. The first turn is always the user's.
    private static func turns(from units: [Unit], droppedConversation: Bool) -> [ContextTurn] {
        var turns: [ContextTurn] = []
        for unit in units where !unit.text.isEmpty {
            if let last = turns.last, last.role == unit.role {
                turns[turns.count - 1].blocks.append(unit.text)
                if let id = unit.messageID { turns[turns.count - 1].messageIDs.append(id) }
            } else {
                turns.append(ContextTurn(role: unit.role, blocks: [unit.text], messageIDs: unit.messageID.map { [$0] } ?? []))
            }
        }
        let opening = droppedConversation ? droppedConversationNotice : (turns.first?.role == .assistant ? conversationStartNotice : nil)
        if let opening {
            if turns.first?.role == .user {
                turns[0].blocks.insert(opening, at: 0)
            } else {
                turns.insert(ContextTurn(role: .user, blocks: [opening], messageIDs: []), at: 0)
            }
        }
        return turns
    }

    // MARK: Stable part

    private func stableSections(input: ContextInput, lemmas: [ProblemSnapshot.StatementDigest], omittedLemmas: Int,
                                deadEnds: [ProblemSnapshot.DeadEndDigest], omittedDeadEnds: Int) -> [ContextSection] {
        let snapshot = input.snapshot
        let notation = snapshot.notation.promptBlock()
        let notationCount = snapshot.notation.rows.filter(\.includeInContext).count
        let raw: [(ContextSectionKind, String, String, Int)] = [
            (.rolePrompt, "Role prompt (\(input.rolePrompt.versionTag))", input.rolePrompt.text, 1),
            (.problem, "Problem",
             "<problem>\nTitle: \(snapshot.title)\nStatement: \(snapshot.statementLaTeX)\n</problem>", 1),
            (.notation, "Notation", Self.tagged("notation", notation.isEmpty ? [] : [notation], omitted: 0), notationCount),
            (.adoptedLemmas, "Adopted lemmas", Self.tagged("adopted_lemmas", lemmas.map(Self.lemmaLine), omitted: omittedLemmas),
             lemmas.count),
            (.deadEnds, "Dead ends", Self.tagged("dead_ends", deadEnds.map(Self.deadEndLine), omitted: omittedDeadEnds),
             deadEnds.count),
            (.refutedClaims, "Refuted claims", Self.tagged("refuted_claims", snapshot.refutedClaims.map(Self.refutedLine), omitted: 0),
             snapshot.refutedClaims.count),
        ]
        return raw.map { kind, title, text, count in
            ContextSection(kind: kind, title: title, text: text, itemCount: count, tokens: estimator.blockTokens(text))
        }
    }

    private static func tagged(_ tag: String, _ lines: [String], omitted: Int) -> String {
        var body = lines.isEmpty && omitted == 0 ? ["(none yet)"] : lines
        if omitted > 0 { body.append("(\(omitted) more left out to fit the context window)") }
        return "<\(tag)>\n" + body.joined(separator: "\n") + "\n</\(tag)>"
    }

    static func lemmaLine(_ lemma: ProblemSnapshot.StatementDigest) -> String {
        "- \(lemma.label)" + (lemma.note.map { " (\($0))" } ?? "") + ": \(lemma.statementLaTeX)"
    }

    static func deadEndLine(_ deadEnd: ProblemSnapshot.DeadEndDigest) -> String {
        "- \(deadEnd.name): \(deadEnd.text)"
    }

    static func refutedLine(_ claim: ProblemSnapshot.StatementDigest) -> String {
        "- \(claim.label): \(claim.statementLaTeX)" + (claim.note.map { " Refuted: \($0)" } ?? "")
    }

    // MARK: Transcript

    static let cacheBreakpointMarker = "[cache breakpoint: the provider may cache everything above]"

    private static func transcript(stable: [ContextSection], turns: [ContextTurn]) -> String {
        var out: [String] = []
        for section in stable {
            out.append("[system · \(section.title)]\n\(section.text)")
        }
        out.append(cacheBreakpointMarker)
        for turn in turns {
            out.append("[\(turn.role.rawValue)]\n" + turn.blocks.joined(separator: "\n\n"))
        }
        return out.joined(separator: "\n\n")
    }
}
