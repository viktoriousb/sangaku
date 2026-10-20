import Foundation
import Testing
@testable import sangaku

@Suite("Alignment output: parsing and mapping, failing closed")
struct AlignmentMappingTests {
    private let basis: AlignmentBasis = {
        func side(_ texts: [String]) -> AlignmentBasis.Side {
            AlignmentBasis.Side(attemptID: UUID(), messageID: UUID(), steps: texts.enumerated().map {
                AlignmentBasis.Step(index: $0.offset + 1, stepID: UUID(), revisionID: UUID(), establishes: "e\($0.offset + 1)",
                                    text: $0.element)
            }, partial: false)
        }
        return AlignmentBasis(first: side(["one", "forces $q = p + 1$", "three"]), second: side(["one", "cannot divide"]))
    }()

    private func entry(_ step1: Int, _ step2: Int, _ verdict: String, phrases: (String, String) = ("", ""),
                       note: String = "") -> AlignmentReport.Entry {
        AlignmentReport.Entry(label: "row", step1: step1, step2: step2, note: note, phrase1: phrases.0, phrase2: phrases.1,
                              verdict: verdict)
    }

    @Test("The output is read whole or not at all; an undoubled backslash fails it")
    func parser() {
        let good = #"{"rows":[{"label":"Sylow","step_1":1,"step_2":1,"note":"","phrase_1":"","phrase_2":"","verdict":"equivalent"}],"summary":"Agree."}"#
        #expect(AlignmentParser.parse(good)?.rows.first?.step1 == 1)
        #expect(AlignmentParser.parse(String(good.dropLast(5))) == nil, "cut off")
        #expect(AlignmentParser.parse(good.replacingOccurrences(of: #""step_1":1"#, with: #""step_1":"1""#)) == nil)
        let tab = good.replacingOccurrences(of: #""note":"""#, with: #""note":"\theta""#)
        #expect(AlignmentParser.parse(tab) == nil, #"\t is a control character: the LaTeX was not escaped"#)
    }

    @Test("Mapping: rows by step number, on the revisions shown; nothing from outside the attempts")
    func mapper() throws {
        let report = AlignmentReport(rows: [
            entry(1, 1, "equivalent"),
            entry(2, 2, "diverge", phrases: ("$q = p + 1$", "cannot divide"), note: "Attempt 2 is false at (2, 3)."),
            entry(3, 0, "only_1"),
            entry(9, 0, "only_1"),            // no step 9: dropped
            entry(0, 0, "equivalent"),        // no step at all: dropped
            entry(1, 2, "equivalent"),        // both steps already used: dropped
        ], summary: " They part at step 2. ")
        let draft = try #require(AlignmentMapper.map(report, basis: basis))
        #expect(draft.rows.count == 3 && draft.summary == "They part at step 2.")
        #expect(draft.rows[0].stepAID == basis.first.steps[0].stepID && draft.rows[0].revisionBID == basis.second.steps[0].revisionID)
        #expect(draft.rows[1].verdict == "diverge" && draft.rows[1].keyPhraseA == "$q = p + 1$")
        #expect(draft.rows[1].note == "Attempt 2 is false at (2, 3).")
        #expect(draft.rows[2].verdict == "onlyA" && draft.rows[2].stepBID == nil)
    }

    @Test("Verdicts fail closed, and key phrases must be in the step's text")
    func verdicts() throws {
        let rows = try #require(AlignmentMapper.map(AlignmentReport(rows: [
            entry(1, 1, "maybe"),                                            // unknown: diverge
            entry(2, 2, "only_2", phrases: ("not there", "cannot divide")),  // a pair called one-sided: diverge
            entry(3, 0, "equivalent"),                                       // one step called a pair: stands alone
        ], summary: ""), basis: basis)).rows
        #expect(rows.map(\.verdict) == ["diverge", "diverge", "onlyA"])
        #expect(rows[1].keyPhraseA == nil && rows[1].keyPhraseB == "cannot divide")
        #expect(AlignmentMapper.map(AlignmentReport(rows: [entry(0, 0, "equivalent")], summary: ""), basis: basis) == nil,
                "nothing left: nothing to store")
    }
}

@Suite("Alignment request: context and preparation")
struct AlignmentRequestTests {
    private let fixture = PreviewFixtures.make()

    private var pair: ComparedPair { ComparedPair.oriented(fixture.attemptA.stableID, fixture.attemptB.stableID) }

    private func basis() throws -> AlignmentBasis {
        try #require(AlignmentBasis.make(pair, first: fixture.attemptA, second: fixture.attemptB))
    }

    private func snapshot(live: Set<UUID> = []) -> ProblemSnapshot {
        ProblemSnapshot.make(problem: fixture.problem, branch: fixture.mainBranch,
                             notation: fixture.state.problems.notation(for: fixture.problem),
                             people: [fixture.you, fixture.mk], liveMessageIDs: live)
    }

    private func build(_ basis: AlignmentBasis, live: Set<UUID> = [], provider: String = ProviderID.anthropic) throws -> BuiltContext {
        try ContextBuilder().build(ContextInput(
            snapshot: snapshot(live: live), providerID: provider,
            purpose: .alignment(slot: fixture.slotC.slotID, basis: basis),
            rolePrompt: try #require(PromptLibrary.bundled.prompt(named: "aligner", role: .referee)), pending: nil,
            inputBudget: nil, format: .alignment))
    }

    @Test("The basis is the current text, in the comparison's order")
    func basisOrder() throws {
        let basis = try basis()
        #expect(basis.first.attemptID == pair.first)
        let step5 = fixture.attemptA.sortedSteps[4]
        let sideOfA = basis.first.attemptID == fixture.attemptA.stableID ? basis.first : basis.second
        #expect(sideOfA.steps[4].text == step5.latestRevision?.textLaTeX && sideOfA.steps[4].revisionID == step5.latestRevision?.stableID)
        let reversed = try #require(AlignmentBasis.make(pair, first: fixture.attemptB, second: fixture.attemptA))
        #expect(reversed == basis)
    }

    @Test("Invariants 4 and 9: the aligner sees the two attempts and nothing else, named only Attempt 1 and 2")
    func context() throws {
        let built = try build(basis())
        #expect(built.includedMessageIDs.isEmpty && built.withheldMessageIDs.count == fixture.mainBranch.sortedMessages.count)
        let conversation = built.turns.flatMap(\.blocks).joined(separator: "\n")
        #expect(conversation.contains("[Attempt 1, to align]") && conversation.contains("[Attempt 2, to align]"))
        #expect(conversation.contains("Step 5 (establishes: Resolve q | p + 1): "))
        for letter in ["Model A", "Model B", "Model C", "@A", "@B", "Referee C"] {
            #expect(!conversation.contains(letter), "\(letter)")
        }
        #expect(!conversation.contains("revised by"))
        #expect(built.turns.last?.role == .user && built.format == .alignment && built.promptVersion == "aligner@1")
    }

    @Test("Invariant 4: an attempt still being written is refused; one not on the branch is too")
    func unfinished() throws {
        #expect(throws: ContextError.attemptsUnfinished([fixture.messageB.stableID])) {
            try build(basis(), live: [fixture.messageB.stableID])
        }
        var stray = try basis()
        stray.second.messageID = UUID()
        #expect(throws: ContextError.attemptNotOnBranch(stray.second.messageID)) { try build(stray) }
    }

    @Test("Invariant 15: a provider the problem does not allow is refused before anything else")
    func provider() throws {
        #expect(throws: ContextError.providerNotAllowed("another")) { try build(basis(), provider: "another") }
    }

    @Test("Only a referee-role slot aligns, with the aligner's own prompt and output format")
    func preparer() throws {
        let env = PlannerEnvironment(catalog: .standard, prompts: .bundled, builder: ContextBuilder(),
                                     registry: fixture.state.threads.registry, maxOutputTokens: 4000)
        let snapshot = snapshot()
        let referee = try #require(snapshot.slots.first { $0.id == fixture.slotC.slotID })
        let prepared = try RequestPreparer.prepare(RequestSpec(slot: referee, kind: .align(basis()), effort: .standard),
                                                   snapshot: snapshot, env: env)
        #expect(prepared.built.promptVersion == "aligner@1" && prepared.request.format == .alignment)
        let prover = try #require(snapshot.slots.first { $0.id == fixture.slotA.slotID })
        #expect(throws: SendBlocker.slotCannotReceive(letter: "A", role: .prover)) {
            try RequestPreparer.prepare(RequestSpec(slot: prover, kind: .align(basis()), effort: .standard),
                                        snapshot: snapshot, env: env)
        }
    }
}
