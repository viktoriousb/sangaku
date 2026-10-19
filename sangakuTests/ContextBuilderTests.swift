import Foundation
import Testing
@testable import sangaku

@Suite("Context builder")
struct ContextBuilderTests {
    private let fixture = PreviewFixtures.make()
    private let rolePrompt: RolePrompt
    private let fanOutID: UUID

    init() throws {
        rolePrompt = try #require(PromptLibrary.bundled.prompt(for: .prover))
        fanOutID = try #require(fixture.messageA.proofAttempt?.fanOut?.stableID)
    }

    private func snapshot() -> ProblemSnapshot {
        ProblemSnapshot.make(problem: fixture.problem, branch: fixture.mainBranch,
                             notation: fixture.state.problems.notation(for: fixture.problem),
                             people: [fixture.you, fixture.mk], liveMessageIDs: [])
    }

    private func build(_ snapshot: ProblemSnapshot, purpose: RequestPurpose? = nil, pending: String? = "Next?",
                       budget: Int? = nil, provider: String = ProviderID.anthropic) throws(ContextError) -> BuiltContext {
        try ContextBuilder().build(ContextInput(
            snapshot: snapshot, providerID: provider, purpose: purpose ?? .reply(slot: fixture.slotA.slotID, fanOut: nil),
            rolePrompt: rolePrompt, pending: pending, inputBudget: budget))
    }

    private func section(_ kind: ContextSectionKind, _ built: BuiltContext) -> String {
        built.stable.first { $0.kind == kind }?.text ?? ""
    }

    // MARK: Invariant 15

    @Test("Invariant 15: no request for a provider the problem does not allow, checked before anything else")
    func providerPolicy() throws {
        var snapshot = snapshot()
        snapshot.allowedProviderIDs = []
        #expect(throws: ContextError.providerNotAllowed(ProviderID.anthropic)) { try build(snapshot) }
        snapshot.allowedProviderIDs = ["another-provider"]
        #expect(throws: ContextError.providerNotAllowed(ProviderID.anthropic)) { try build(snapshot) }
        // Even a referee request that would otherwise wait reports the policy first.
        let index = try #require(snapshot.messages.firstIndex { $0.id == fixture.messageB.stableID })
        snapshot.messages[index].outcome = .streaming
        #expect(throws: ContextError.providerNotAllowed(ProviderID.anthropic)) {
            try build(snapshot, purpose: .referee(slot: fixture.slotC.slotID, fanOut: fanOutID))
        }
        snapshot.allowedProviderIDs = [ProviderID.anthropic]
        _ = try build(snapshot)
    }

    // MARK: Invariant 5

    @Test("Invariant 5: every request carries the problem, the notation with its macros, dead ends and refuted claims")
    func carriesEssentials() throws {
        let built = try build(snapshot())
        #expect(built.stable.map(\.kind) == ContextSectionKind.allCases, "stable part first, in a fixed order")
        #expect(section(.rolePrompt, built) == rolePrompt.text)
        #expect(section(.problem, built).contains(fixture.problem.statementLaTeX))
        #expect(section(.notation, built).contains(#"(macro: \DeclareMathOperator{\Syl}{Syl})"#))
        #expect(section(.notation, built).contains("number of Sylow $r$-subgroups"))
        let deadEnds = section(.deadEnds, built)
        #expect(deadEnds.contains("- Class equation: Tried: class equation alone. Stalls on |Z(G)|."))
        #expect(deadEnds.contains("- Induction on |G|:"))
        #expect(!deadEnds.contains("Normal p-complement"), "a parked branch is not a dead end")
        #expect(section(.refutedClaims, built).contains(#"- Claim: $n_q = p$ is possible. Refuted: $n_q = p$ needs"#))
        let lemmas = section(.adoptedLemmas, built).split(separator: "\n").map(String.init)
        #expect(lemmas.filter { $0.hasPrefix("- ") }.map { $0.prefix { $0 != "(" } } == [
            "- Lem 1 ", "- Lem 2 ", "- Lem 3 ", "- Lem 4 ", "- Lem 5 ", "- Lem 6 ", "- Lem 7 ",
        ], "every statement but the theorem, the refuted claim and the conjecture, in the graph's order")
        #expect(lemmas.contains(#"- Lem 1 (verified in Lean): $n_p \in \{1, q\}$ with $n_p \equiv 1 \pmod{p}$, and $n_q \in \{1, p, p^2\}$ with $n_q \equiv 1 \pmod{q}$."#))
        #expect(lemmas.contains("- Lem 5 (sketched; capped by Lem 3 (sketched)): The case $n_p = q$, $n_q = p^2$ does not occur."),
                "invariant 13: a capped lemma is sent with its displayed status, never its own")
        #expect(lemmas.contains(#"- Lem 7 (sketched; capped by Lem 6 (sketched); depends on a refuted claim through Lem 6): $n_q = p$ contradicts $q > p$."#))
        #expect(built.transcript.contains(ContextBuilder.cacheBreakpointMarker))
    }

    @Test("Invariant 7: a step a person revised says who, in words a model can read; a model's own revision does not")
    func personRevisions() throws {
        let transcript = try build(snapshot()).transcript
        #expect(transcript.contains("Step 3 (establishes: n_q = p^2; confidence: routine; revised by the researcher): "))
        #expect(transcript.contains("Step 5 (establishes: Resolve q | p + 1; confidence: delicate): "),
                "A revised its own step 5")
        #expect(!transcript.contains("revised by You"))
        let step4 = fixture.attemptA.sortedSteps[3]
        let revision = StepRevision(author: .human(fixture.mk.personID), textLaTeX: "MK's wording.",
                                    establishes: step4.establishes)
        revision.createdAt = .now
        step4.revisions = (step4.revisions ?? []) + [revision]
        step4.textLaTeX = revision.textLaTeX
        #expect(try build(snapshot()).transcript.contains("Step 4 (establishes: q | p + 1; confidence: routine; revised by MK): MK's wording."))
    }

    @Test("Adopted lemmas are carried with their status")
    func adoptedLemmas() throws {
        var snapshot = snapshot()
        snapshot.adoptedLemmas = [.init(id: UUID(), createdAt: .now, label: "Lem 1",
                                        statementLaTeX: #"$n_p \in \{1, q\}$"#, note: "checked by a person")]
        #expect(section(.adoptedLemmas, try build(snapshot)) == "<adopted_lemmas>\n- Lem 1 (checked by a person): $n_p \\in \\{1, q\\}$\n</adopted_lemmas>")
    }

    @Test("Invariant 5: lemmas are sent in one order, whatever order the snapshot holds them in")
    func lemmaOrder() throws {
        var shuffled = snapshot()
        shuffled.adoptedLemmas.reverse()
        #expect(section(.adoptedLemmas, try build(shuffled)) == section(.adoptedLemmas, try build(snapshot())))
    }

    @Test("Entries switched out of context are left out; the others stay")
    func toggledOffEntries() throws {
        let syl = try #require(fixture.problem.sortedNotation.first { $0.macroDefinition != nil })
        fixture.state.problems.setIncludeInContext(syl, false)
        try #require(fixture.problem.sortedBranches.first { $0.name == "Class equation" }).includeReasonInContext = false
        let built = try build(snapshot())
        #expect(!section(.notation, built).contains("DeclareMathOperator"))
        #expect(!section(.deadEnds, built).contains("Class equation"))
        #expect(section(.deadEnds, built).contains("Induction on |G|"))
    }

    @Test("A dead end without text for models falls back to its reason, then says none was recorded")
    func deadEndText() {
        let branch = Branch(name: "Try", state: .deadEnd)
        #expect(branch.textForModels == "(no reason recorded)")
        branch.reason = "For people."
        #expect(branch.textForModels == "For people.")
        branch.reasonForModels = "  For models. "
        #expect(branch.textForModels == "For models.")
    }

    @Test("A refutation counts only when a person accepted it (invariant 1)")
    func refutedNeedsAPerson() throws {
        fixture.refutedClaim.refutationAcceptedByID = fixture.slotA.stableID
        #expect(section(.refutedClaims, try build(snapshot())).contains("(none yet)"))
    }

    @Test("The stable part does not change when only the conversation does, so it stays cached")
    func stablePrefix() throws {
        let snapshot = snapshot()
        #expect(try build(snapshot, pending: "One").stable == build(snapshot, pending: "Two").stable)
    }

    // MARK: Invariant 5, drop order

    private let me = UUID()
    private let slotA = ModelSlotID(UUID())

    private func longSnapshot() -> ProblemSnapshot {
        var snapshot = ProblemSnapshot(problemID: UUID(), title: "T", statementLaTeX: "Let $G$ be a group.",
                                       allowedProviderIDs: [ProviderID.anthropic], notation: NotationRegistry(rows: []),
                                       branchID: UUID())
        snapshot.meID = me
        snapshot.people = [me: "You"]
        snapshot.slots = [.init(id: slotA, letter: "A", providerID: ProviderID.anthropic, modelID: "m", role: .prover)]
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<6 {
            snapshot.messages.append(.init(id: UUID(), createdAt: start + Double(2 * i), author: .human(PersonID(me)),
                                           kind: .prompt, body: "Question \(i): " + String(repeating: "q", count: 800)))
            snapshot.messages.append(.init(id: UUID(), createdAt: start + Double(2 * i + 1), author: .model(slotA),
                                           kind: .reply, body: "Answer \(i): " + String(repeating: "a", count: 800)))
        }
        snapshot.deadEnds = (0..<2).map {
            .init(id: UUID(), createdAt: start + Double($0), name: "Dead end \($0)", text: String(repeating: "d", count: 400))
        }
        snapshot.adoptedLemmas = (0..<2).map {
            .init(id: UUID(), createdAt: start + Double($0), label: "Lem \($0)", statementLaTeX: String(repeating: "l", count: 400))
        }
        snapshot.refutedClaims = [.init(id: UUID(), createdAt: start, label: "Claim", statementLaTeX: "$1 = 2$", note: "false")]
        return snapshot
    }

    /// Older exchanges oldest first, then dead ends, then adopted lemmas, then the latest exchange.
    private var canonicalDropOrder: [String] {
        func question(_ i: Int) -> String { "Message|You · " + String(("Question \(i): " + String(repeating: "q", count: 800)).prefix(60)) }
        func answer(_ i: Int) -> String { "Message|Model A · " + String(("Answer \(i): " + String(repeating: "a", count: 800)).prefix(60)) }
        return (0..<5).flatMap { [question($0), answer($0)] } + ["Dead end|Dead end 0", "Dead end|Dead end 1",
                                                                 "Adopted lemma|Lem 0", "Adopted lemma|Lem 1",
                                                                 question(5), answer(5)]
    }

    @Test("Invariant 5: over every budget, items drop in the defined order, the rest fits, essentials stay")
    func dropOrderSweep() throws {
        let snapshot = longSnapshot()
        let purpose = RequestPurpose.reply(slot: slotA, fanOut: nil)
        let full = try build(snapshot, purpose: purpose, pending: "Now?").totalTokens
        var previous = 0
        var refused = false
        for budget in stride(from: Int(Double(full) * 1.2), through: 0, by: -40) {
            do {
                let built = try build(snapshot, purpose: purpose, pending: "Now?", budget: budget)
                #expect(!refused, "a larger budget was refused, a smaller one accepted")
                #expect(Double(built.totalTokens) * ContextBuilder.fitMargin <= Double(budget))
                let dropped = built.dropped.map { "\($0.kind)|\($0.title)" }
                #expect(dropped == Array(canonicalDropOrder.prefix(dropped.count)), "budget \(budget)")
                #expect(dropped.count >= previous)
                previous = dropped.count
                for essential in ["Let $G$ be a group.", "$1 = 2$", "Now?", rolePrompt.text] {
                    #expect(built.transcript.contains(essential))
                }
                if !dropped.isEmpty {
                    #expect(!built.transcript.contains("Question 0:"))
                    #expect(built.transcript.contains(ContextBuilder.droppedConversationNotice), "the model is told")
                }
                if case .dropped(let count, _, _) = built.fit { #expect(count == dropped.count) }
            } catch {
                guard case .essentialsDoNotFit = error else { throw error }
                refused = true
            }
        }
        #expect(refused, "a small enough window refuses rather than truncating the essentials")
        #expect(previous == canonicalDropOrder.count, "just above the essentials everything optional was dropped")
    }

    @Test("A window too small for the essentials refuses; an unknown window drops nothing")
    func essentialsAndUnknownWindow() throws {
        let snapshot = longSnapshot()
        let purpose = RequestPurpose.reply(slot: slotA, fanOut: nil)
        #expect(throws: ContextError.self) { try build(snapshot, purpose: purpose, budget: 10) }
        let unknown = try build(snapshot, purpose: purpose, budget: nil)
        #expect(unknown.dropped.isEmpty)
        if case .unknownWindow = unknown.fit {} else { Issue.record("expected an unknown window") }
    }

    // MARK: Conversation

    @Test("Turns alternate, begin and end with the user, and keep authorship visible")
    func turnMapping() throws {
        let built = try build(snapshot())
        #expect(built.turns.first?.role == .user)
        #expect(built.turns.last?.role == .user)
        for (earlier, later) in zip(built.turns, built.turns.dropFirst()) { #expect(earlier.role != later.role) }
        #expect(built.turns.allSatisfy { !$0.blocks.contains("") })
        let text = built.transcript
        #expect(text.contains("[Attempt by Model B]\nStep 1 (establishes: Sylow counts; confidence: standard)"))
        #expect(text.contains("[Referee C]\nA's proof is complete. B's step 5 is false"))
        #expect(text.contains("Verdict on Model B's attempt: gap at step 5. B's step 5 is false"),
                "later models hear the referee's verdicts, not only its summary")
        #expect(text.contains("[This reply was stopped before it finished.]"))
        #expect(built.includedMessageIDs.contains(fixture.interruptedReply.stableID))
        #expect(!built.includedMessageIDs.contains(fixture.failedReply.stableID), "a failed reply with no text is left out")
        #expect(text.hasSuffix("Next?"))
    }

    @Test("A declined reply is never passed on")
    func declinedIsLeftOut() throws {
        var snapshot = snapshot()
        let index = try #require(snapshot.messages.firstIndex { $0.id == fixture.reply.stableID })
        snapshot.messages[index].outcome = .declined(category: nil)
        #expect(!(try build(snapshot)).includedMessageIDs.contains(fixture.reply.stableID))
    }

    @Test("Without a new message the conversation must end with someone else's turn")
    func nothingToAnswer() throws {
        var snapshot = snapshot()
        snapshot.messages.removeLast(2)
        #expect(throws: ContextError.nothingToAnswer) { try build(snapshot, pending: nil) }
        snapshot.messages.removeLast()
        _ = try build(snapshot, pending: nil)
    }

    // MARK: Invariant 4

    @Test("Invariant 4: an independent attempt never sees its siblings or anything derived from them")
    func independentAttempt() throws {
        let built = try build(snapshot(), purpose: .reply(slot: fixture.slotA.slotID, fanOut: fanOutID))
        #expect(built.withheldMessageIDs.contains(fixture.messageB.stableID))
        #expect(built.withheldMessageIDs.contains(fixture.refereeMessage.stableID), "the referee saw B")
        #expect(!built.transcript.contains("cannot divide $p + 1$"), "B's step 5")
        #expect(!built.transcript.contains("B's step 5 is false"))
        #expect(built.includedMessageIDs.contains(fixture.messageA.stableID), "A sees its own attempt")
        #expect(built.transcript.contains("contribute $8$ elements of order $3$"))
    }

    @Test("Invariant 4: derivation is followed transitively, and unlinked messages by other models are withheld")
    func derivedAndUnlinked() throws {
        var snapshot = snapshot()
        let later = Date.now.addingTimeInterval(3600)
        let quote = ProblemSnapshot.MessageDigest(id: UUID(), createdAt: later, author: .human(PersonID(fixture.you.stableID)),
                                                  kind: .prompt, body: "QUOTING THE REFEREE",
                                                  derivedFromIDs: [fixture.refereeMessage.stableID])
        let answer = ProblemSnapshot.MessageDigest(id: UUID(), createdAt: later + 1, author: .human(PersonID(fixture.mk.stableID)),
                                                   kind: .prompt, body: "ANSWERING THE QUOTE", derivedFromIDs: [quote.id])
        let unlinked = ProblemSnapshot.MessageDigest(id: UUID(), createdAt: later + 2, author: .model(fixture.slotB.slotID),
                                                     kind: .reply, body: "UNLINKED BY B")
        snapshot.messages += [quote, answer, unlinked]
        let built = try build(snapshot, purpose: .reply(slot: fixture.slotA.slotID, fanOut: fanOutID))
        #expect(Set([quote.id, answer.id, unlinked.id]).isSubset(of: built.withheldMessageIDs))
        for text in ["QUOTING THE REFEREE", "ANSWERING THE QUOTE", "UNLINKED BY B"] { #expect(!built.transcript.contains(text)) }
    }

    @Test("A shared fan-out withholds nothing, and neither does an ordinary reply")
    func sharedAndOrdinary() throws {
        var shared = snapshot()
        shared.fanOuts[0].visibility = .shared
        #expect(try build(shared, purpose: .reply(slot: fixture.slotA.slotID, fanOut: fanOutID)).withheldMessageIDs.isEmpty)
        #expect(try build(snapshot()).transcript.contains("cannot divide $p + 1$"))
    }

    @Test("Invariant 4: the referee waits for every attempt and sees a stopped one marked partial")
    func referee() throws {
        var snapshot = snapshot()
        let index = try #require(snapshot.messages.firstIndex { $0.id == fixture.messageB.stableID })
        let purpose = RequestPurpose.referee(slot: fixture.slotC.slotID, fanOut: fanOutID)
        snapshot.messages[index].outcome = .streaming
        #expect(throws: ContextError.attemptsUnfinished([fixture.messageB.stableID])) { try build(snapshot, purpose: purpose) }
        snapshot.messages[index].outcome = .interrupted
        let built = try build(snapshot, purpose: purpose)
        #expect(built.partialAttemptIDs == [fixture.messageB.stableID])
        #expect(built.transcript.contains("[PARTIAL attempt by Model B, to judge: stopped before finishing]"))
        #expect(built.transcript.contains("cannot divide $p + 1$"), "the referee sees every attempt")
        // The branch as it stood when the last attempt was written: a second referee judges afresh, without the
        // first one's verdicts or the later reply that discusses them.
        let later = snapshot.messages.filter { $0.createdAt > snapshot.messages[index].createdAt }.map(\.id)
        #expect(built.withheldMessageIDs == later)
        #expect(later.contains(fixture.refereeMessage.stableID) && later.contains(fixture.reply.stableID))
        #expect(!built.transcript.contains("Verdict on Model"))
        #expect(!built.transcript.contains("It is forced rather than special"))
    }

    @Test("Invariant 4: with two fan-outs on a branch, the referee is told which attempts are its to judge")
    func refereeOfASecondFanOut() throws {
        var snapshot = snapshot()
        let start = Date.now.addingTimeInterval(3_600)
        let prompt = ProblemSnapshot.MessageDigest(id: UUID(), createdAt: start, author: .human(PersonID(fixture.you.stableID)),
                                                   kind: .prompt, body: "Now for p^2 q^2.")
        let second = ProblemSnapshot.MessageDigest(id: UUID(), createdAt: start + 1, author: .model(fixture.slotA.slotID),
                                                   kind: .attempt, body: "SECOND ATTEMPT BY A", fanOutID: UUID())
        let fanOut = ProblemSnapshot.FanOutDigest(id: UUID(), visibility: .independent, requestMessageID: prompt.id,
                                                  attemptMessageIDs: [second.id], refereeSlotID: fixture.slotC.slotID.rawValue)
        snapshot.messages += [prompt, second]
        snapshot.fanOuts.append(fanOut)
        let text = try build(snapshot, purpose: .referee(slot: fixture.slotC.slotID, fanOut: fanOut.id)).transcript
        #expect(text.contains("[Attempt by Model A, to judge]\nSECOND ATTEMPT BY A"))
        #expect(text.contains("[Attempt by Model A]\nStep 1"), "the first fan-out's attempt is context, not to judge")
        #expect(!text.contains("[Attempt by Model B, to judge]"))
    }

    @Test("A referee run again ends with an instruction of the person's, so it is never refused for having nothing to answer")
    func refereeAgain() throws {
        var snapshot = snapshot()
        let purpose = RequestPurpose.referee(slot: fixture.slotC.slotID, fanOut: fanOutID)
        // The first referee's message would be the model's own last turn; it is withheld, so the attempts end it.
        snapshot.messages.removeAll { $0.createdAt > fixture.refereeMessage.createdAt }
        #expect(try build(snapshot, purpose: purpose, pending: nil).turns.last?.role == .user)
        let built = try build(snapshot, purpose: purpose, pending: RequestPreparer.refereeInstruction(letters: ["A", "B"]))
        #expect(built.turns.last?.role == .user)
        #expect(built.transcript.hasSuffix("Give your verdict on each attempt above (Model A, Model B), identified by its letter."))
    }

    @Test("Provenance: a message is labelled with the role it was written in, not its slot's role now")
    func labelsFollowKind() throws {
        var snapshot = snapshot()
        let index = try #require(snapshot.slots.firstIndex { $0.id == fixture.slotA.slotID })
        snapshot.slots[index].role = .scout
        let text = try build(snapshot, purpose: .reply(slot: fixture.slotB.slotID, fanOut: nil)).transcript
        #expect(text.contains("[Model A · prover]"))
        #expect(!text.contains("scout"))
    }

    @Test("In a fan-out the prompt stays with the attempts: what is dropped first is older, never the request")
    func fanOutKeepsItsPrompt() throws {
        var shared = longSnapshot()
        let slotB = ModelSlotID(UUID())
        shared.slots.append(.init(id: slotB, letter: "B", providerID: ProviderID.anthropic, modelID: "m", role: .prover))
        let fanOutID = UUID()
        let request = ProblemSnapshot.MessageDigest(id: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: 100),
                                                    author: .human(PersonID(me)), kind: .prompt, body: "THE FAN-OUT'S QUESTION")
        let earlier = ProblemSnapshot.MessageDigest(id: UUID(), createdAt: request.createdAt + 1, author: .model(slotA),
                                                    kind: .attempt, body: "A'S ATTEMPT", fanOutID: fanOutID)
        shared.messages += [request, earlier]
        shared.fanOuts = [ProblemSnapshot.FanOutDigest(id: fanOutID, visibility: .shared, requestMessageID: request.id,
                                                       attemptMessageIDs: [earlier.id], refereeSlotID: nil)]
        var bare = shared
        bare.messages = [request, earlier]
        bare.deadEnds = []
        bare.adoptedLemmas = []
        let purpose = RequestPurpose.reply(slot: slotB, fanOut: fanOutID)
        let minimum = try build(bare, purpose: purpose, pending: nil).totalTokens
        // Room for the essentials, the fan-out and the notes about what was left out, and nothing more.
        let tight = try build(shared, purpose: purpose, pending: nil, budget: Int(Double(minimum) * ContextBuilder.fitMargin) + 60)
        #expect(!tight.dropped.isEmpty)
        #expect(!tight.dropped.contains { $0.title.contains("THE FAN-OUT'S QUESTION") })
        #expect(tight.transcript.contains("THE FAN-OUT'S QUESTION"))
        #expect(tight.transcript.hasSuffix("A'S ATTEMPT"))
    }

    @Test("Invariant 4: the referee hears about every attempt, even one with no text or one that was declined")
    func refereeHearsTextlessAttempts() throws {
        var snapshot = snapshot()
        let index = try #require(snapshot.messages.firstIndex { $0.id == fixture.messageB.stableID })
        snapshot.messages[index].steps = []
        snapshot.messages[index].body = ""
        snapshot.messages[index].outcome = .interrupted
        let purpose = RequestPurpose.referee(slot: fixture.slotC.slotID, fanOut: fanOutID)
        let stopped = try build(snapshot, purpose: purpose)
        #expect(stopped.transcript.contains("[PARTIAL attempt by Model B, to judge: stopped before finishing]\n(no text arrived)"))
        #expect(stopped.includedMessageIDs.contains(fixture.messageB.stableID))
        #expect(stopped.partialAttemptIDs == [fixture.messageB.stableID])
        snapshot.messages[index].outcome = .declined(category: nil)
        let declined = try build(snapshot, purpose: purpose)
        #expect(declined.transcript.contains("[Attempt by Model B, to judge: declined by the provider; there is no attempt]"))
        #expect(declined.partialAttemptIDs.isEmpty)
    }

    @Test("A fan-out or attempt that is not on the branch is refused, never built without its rules")
    func fanOutNotOnBranch() throws {
        let missing = UUID()
        #expect(throws: ContextError.fanOutNotOnBranch(missing)) {
            try build(snapshot(), purpose: .reply(slot: fixture.slotA.slotID, fanOut: missing))
        }
        #expect(throws: ContextError.fanOutNotOnBranch(missing)) {
            try build(snapshot(), purpose: .referee(slot: fixture.slotC.slotID, fanOut: missing))
        }
        var snapshot = snapshot()
        snapshot.messages.removeAll { $0.id == fixture.messageB.stableID }
        #expect(throws: ContextError.fanOutNotOnBranch(fanOutID)) {
            try build(snapshot, purpose: .referee(slot: fixture.slotC.slotID, fanOut: fanOutID))
        }
    }

    @Test("A reply that ended early is passed on marked as possibly incomplete")
    func endedEarlyIsMarked() throws {
        var snapshot = snapshot()
        let index = try #require(snapshot.messages.firstIndex { $0.id == fixture.reply.stableID })
        snapshot.messages[index].outcome = .endedEarly(reason: "pause_turn")
        #expect(try build(snapshot).transcript.contains("[This reply ended early (pause_turn) and may be incomplete.]"))
    }

    // MARK: Snapshot

    @Test("The snapshot reads outcomes, fan-outs and only person-accepted refutations from the store")
    func snapshotContents() {
        let snapshot = snapshot()
        #expect(snapshot.message(fixture.interruptedReply.stableID)?.outcome == .interrupted)
        if case .failed(let kind, _)? = snapshot.message(fixture.failedReply.stableID)?.outcome {
            #expect(kind == "overloaded_error")
        } else {
            Issue.record("the failed reply should read as failed")
        }
        #expect(snapshot.message(fixture.reply.stableID)?.outcome == .complete)
        #expect(snapshot.fanOuts.count == 1)
        #expect(Set(snapshot.fanOuts[0].attemptMessageIDs) == [fixture.messageA.stableID, fixture.messageB.stableID])
        #expect(snapshot.refutedClaims.map(\.label) == ["Claim"])
        #expect(snapshot.deadEnds.map(\.name) == ["Class equation", "Induction on |G|"])
        #expect(snapshot.meID == fixture.you.stableID)
        let live = ProblemSnapshot.make(problem: fixture.problem, branch: fixture.mainBranch,
                                        notation: fixture.state.problems.notation(for: fixture.problem),
                                        people: [fixture.you], liveMessageIDs: [fixture.reply.stableID])
        #expect(live.message(fixture.reply.stableID)?.outcome == .streaming)
    }
}
