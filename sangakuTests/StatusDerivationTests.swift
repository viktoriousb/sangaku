import Foundation
import Testing
@testable import sangaku

/// A seeded generator, so random graphs are the same on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

@Suite("Dependency cap (invariant 13)")
struct StatusDerivationTests {
    @Test("Refuted is outside the order; the others rise strictly")
    func ladder() {
        #expect(StatementStatus.refuted.trustRank == nil)
        #expect(StatementStatus.ladder.map(\.trustRank) == [0, 1, 2, 3, 4])
        #expect(Set(StatementStatus.ladder + [.refuted]) == Set(StatementStatus.allCases))
    }

    @Test("Invariant 13: a statement displays the lower of its own status and its dependency's")
    func capTable() {
        for own in StatementStatus.ladder {
            for dependency in StatementStatus.ladder {
                let (user, used) = (UUID(), UUID())
                let derived = StatusDerivation.derive([
                    StatementFacts(id: user, own: own, uses: [used]),
                    StatementFacts(id: used, own: dependency, uses: []),
                ])
                let expected = StatementStatus.ladder[min(own.trustRank ?? 0, dependency.trustRank ?? 0)]
                #expect(derived[user]?.displayed == expected, "\(own) using \(dependency)")
                #expect(derived[user]?.caps.map(\.dependency) == (expected == own ? [] : [used]))
                #expect(derived[used]?.displayed == dependency)
            }
        }
    }

    @Test("Invariant 13: a refuted dependency caps at sketched and is always reported")
    func refutedDependency() {
        let refuted = UUID()
        for own in StatementStatus.ladder {
            let user = UUID()
            let derived = StatusDerivation.derive([
                StatementFacts(id: user, own: own, uses: [refuted]),
                StatementFacts(id: refuted, own: .refuted, uses: []),
            ])
            let status = derived[user]
            #expect(status?.displayed == (own == .proposed ? .proposed : .sketched), "\(own)")
            #expect(status?.dependsOnRefuted == true, "\(own): the refuted dependency must stay visible")
            if own.trustRank ?? 0 > 1 {
                #expect(status?.caps.first?.dependencyIsRefuted == true)
            }
        }
        #expect(StatusDerivation.derive([StatementFacts(id: refuted, own: .refuted, uses: [])])[refuted]?.displayed == .refuted)
    }

    @Test("Invariant 13: a refuted statement stays refuted, whatever it uses")
    func refutedStaysRefuted() {
        let (claim, weak) = (UUID(), UUID())
        let derived = StatusDerivation.derive([
            StatementFacts(id: claim, own: .refuted, uses: [weak]),
            StatementFacts(id: weak, own: .proposed, uses: []),
        ])
        #expect(derived[claim]?.displayed == .refuted)
        #expect(derived[claim]?.caps.isEmpty == true)
        #expect(derived[claim]?.isCapped == false)
    }

    @Test("Invariant 13: a refuted claim is reported through any number of statements")
    func refutedIsTransitive() {
        let (a, b, refuted, unrelated) = (UUID(), UUID(), UUID(), UUID())
        let derived = StatusDerivation.derive([
            StatementFacts(id: a, own: .humanChecked, uses: [b]),
            StatementFacts(id: b, own: .humanChecked, uses: [refuted]),
            StatementFacts(id: refuted, own: .refuted, uses: []),
            StatementFacts(id: unrelated, own: .humanChecked, uses: []),
        ])
        #expect(derived[a]?.dependsOnRefuted == true)
        #expect(derived[b]?.dependsOnRefuted == true)
        #expect(derived[a]?.displayed == .sketched)
        #expect(derived[unrelated]?.dependsOnRefuted == false)
        #expect(derived[refuted]?.dependsOnRefuted == false)
    }

    @Test("Invariant 13: the cap reads a dependency's displayed status, not its own")
    func capIsTransitive() {
        let (top, middle, leaf) = (UUID(), UUID(), UUID())
        let derived = StatusDerivation.derive([
            StatementFacts(id: top, own: .formallyVerified, uses: [middle]),
            StatementFacts(id: middle, own: .humanChecked, uses: [leaf]),
            StatementFacts(id: leaf, own: .sketched, uses: []),
        ])
        #expect(derived[middle]?.displayed == .sketched)
        #expect(derived[top]?.displayed == .sketched)
        #expect(derived[top]?.caps.map(\.dependency) == [middle], "the binding dependency is the one it uses")
    }

    @Test("Every binding dependency is named; order and duplicates in uses change nothing")
    func bindingCaps() {
        let (user, x, y, z) = (UUID(), UUID(), UUID(), UUID())
        let facts = [
            StatementFacts(id: x, own: .modelChecked, uses: []),
            StatementFacts(id: y, own: .modelChecked, uses: []),
            StatementFacts(id: z, own: .humanChecked, uses: []),
        ]
        let forward = StatusDerivation.derive(facts + [StatementFacts(id: user, own: .humanChecked, uses: [x, y, z])])
        let shuffled = StatusDerivation.derive([StatementFacts(id: user, own: .humanChecked, uses: [z, y, x, y, z])] + facts.reversed())
        #expect(Set(forward[user]?.caps.map(\.dependency) ?? []) == [x, y])
        #expect(forward[user]?.displayed == .modelChecked)
        #expect(shuffled[user]?.displayed == forward[user]?.displayed)
        #expect(Set(shuffled[user]?.caps.map(\.dependency) ?? []) == [x, y])
    }

    @Test("A dependency outside the problem counts as proposed")
    func missingDependency() {
        let (user, gone) = (UUID(), UUID())
        let derived = StatusDerivation.derive([StatementFacts(id: user, own: .humanChecked, uses: [gone])])
        #expect(derived[user]?.displayed == .proposed)
        #expect(derived[user]?.caps.first?.dependencyIsMissing == true)
    }

    @Test("Cycles in the data end and fail closed: proposed, flagged, a refuted member stays refuted")
    func cyclesFailClosed() {
        let (selfUser, a, b, c, d, below, refuted) = (UUID(), UUID(), UUID(), UUID(), UUID(), UUID(), UUID())
        let derived = StatusDerivation.derive([
            StatementFacts(id: selfUser, own: .humanChecked, uses: [selfUser]),
            StatementFacts(id: a, own: .formallyVerified, uses: [b]),
            StatementFacts(id: b, own: .humanChecked, uses: [a]),
            StatementFacts(id: c, own: .humanChecked, uses: [d]),
            StatementFacts(id: d, own: .humanChecked, uses: [refuted]),
            StatementFacts(id: refuted, own: .refuted, uses: [c]),
            StatementFacts(id: below, own: .humanChecked, uses: [a]),
        ])
        for id in [selfUser, a, b, c, d, below] {
            #expect(derived[id]?.displayed == .proposed)
            #expect(derived[id]?.isUnresolved == true)
        }
        #expect(derived[refuted]?.displayed == .refuted)
        #expect(derived[c]?.dependsOnRefuted == true)
        #expect(derived[refuted]?.dependsOnRefuted == true, "on a cycle through itself")
    }

    @Test("A long chain is derived without recursion")
    func longChain() {
        let chain = ids(10_000)
        var facts = [StatementFacts(id: chain[0], own: .modelChecked, uses: [])]
        for index in 1..<chain.count {
            facts.append(StatementFacts(id: chain[index], own: .formallyVerified, uses: [chain[index - 1]]))
        }
        let derived = StatusDerivation.derive(facts.reversed())
        #expect(derived[chain[chain.count - 1]]?.displayed == .modelChecked)
        #expect(derived.count == chain.count)
    }

    @Test("Invariant 13: random graphs agree with the definition, and nothing outranks a dependency")
    func randomGraphs() {
        var generator = SplitMix64(state: 0x5A_4E_6A_6B)
        for _ in 0..<200 {
            let count = Int.random(in: 1...12, using: &generator)
            let nodes = ids(count)
            // Edges only go to earlier nodes, so the graph is acyclic.
            let facts = nodes.enumerated().map { index, id in
                let own = StatementStatus.allCases.randomElement(using: &generator) ?? .proposed
                let uses = (0..<index).filter { _ in Int.random(in: 0..<3, using: &generator) == 0 }.map { nodes[$0] }
                return StatementFacts(id: id, own: own, uses: uses)
            }
            let derived = StatusDerivation.derive(facts.shuffled(using: &generator))
            let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
            func reference(_ id: UUID) -> StatementStatus {
                guard let fact = byID[id], let own = fact.own.trustRank else { return .refuted }
                let ranks = fact.uses.map { byID[$0]?.own == .refuted ? 1 : (reference($0).trustRank ?? 0) }
                return StatementStatus.ladder[([own] + ranks).min() ?? own]
            }
            for fact in facts {
                let displayed = derived[fact.id]?.displayed
                #expect(displayed == reference(fact.id))
                guard let rank = displayed?.trustRank else { continue }
                #expect(rank <= fact.own.trustRank ?? 0)
                for dependency in fact.uses {
                    let ceiling = byID[dependency]?.own == .refuted ? 1 : (derived[dependency]?.displayed.trustRank ?? 0)
                    #expect(rank <= ceiling, "displayed above a dependency")
                }
            }
        }
    }
}

@Suite("Uses graph")
struct UsesGraphTests {
    @Test("Invariant 13: an edge that would close a cycle is found, with its path")
    func cycles() throws {
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        let graph = UsesGraph(uses: [a: [b], b: [c], c: [], d: [b]])
        #expect(graph.cyclePath(adding: a, uses: a) == [a, a])
        #expect(graph.cyclePath(adding: b, uses: a) == [b, a, b])
        #expect(graph.cyclePath(adding: c, uses: a) == [c, a, b, c])
        #expect(graph.cyclePath(adding: a, uses: c) == nil, "a shortcut is not a cycle")
        #expect(graph.cyclePath(adding: d, uses: c) == nil)
        #expect(graph.ancestors(of: c) == [a, b, d])
    }

    @Test("Candidates leave out the statement, what it already uses and whatever uses it")
    func candidates() {
        let (a, b, c, d, e) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let graph = UsesGraph(uses: [a: [b], b: [c], d: []])
        #expect(graph.candidates(for: b, among: [a, b, c, d, e]) == [d, e])
        #expect(graph.candidates(for: a, among: [a, b, c, d, e]) == [c, d, e])
    }
}

@Suite("Statement labels")
struct StatementLabelTests {
    @Test func nextLabel() {
        #expect(StatementLabels.next(for: .lemma, existing: []) == "Lem 1")
        #expect(StatementLabels.next(for: .lemma, existing: ["Thm 1", "Lem 1", "Lem 4", "Claim"]) == "Lem 5")
        #expect(StatementLabels.next(for: .claim, existing: ["Claim"]) == "Claim 2")
        #expect(StatementLabels.next(for: .lemma, existing: ["Lemma 3", "Lem x", " lem 7 "]) == "Lem 8")
    }

    @Test func taken() {
        #expect(StatementLabels.isTaken(" lem 3", among: ["Lem 3"]))
        #expect(!StatementLabels.isTaken("Lem 30", among: ["Lem 3"]))
    }

    @Test("Numbers at the edge of Int neither crash nor wrap")
    func extremes() {
        #expect(StatementLabels.next(for: .lemma, existing: ["Lem \(Int.max)"]) == "Lem \(Int.max)")
        #expect(StatementLabels.rangeText([Int.max - 1, Int.max, Int.min]) == "\(Int.min), \(Int.max - 1)–\(Int.max)")
    }

    @Test("A label reads as a heading")
    func headings() {
        #expect(StatementLabels.heading("Lem 3", kind: .lemma) == "Lemma 3")
        #expect(StatementLabels.heading("Thm 1", kind: .theorem) == "Theorem 1")
        #expect(StatementLabels.heading("Claim", kind: .claim) == "Claim")
        #expect(StatementLabels.heading("Sylow counts", kind: .lemma) == "Sylow counts")
    }

    @Test func ranges() {
        #expect(StatementLabels.rangeText([1, 3, 4, 5]) == "1, 3–5")
        #expect(StatementLabels.rangeText([6]) == "6")
        #expect(StatementLabels.rangeText([5, 4, 4, 3]) == "3–5")
        #expect(StatementLabels.rangeText([]) == "")
    }
}

@Suite("Statement graph state")
struct StatementGraphStateTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func record(_ id: UUID, _ label: String, kind: StatementKind = .lemma, own: StatementStatus,
                        uses: [UUID] = [], at offset: Double = 0) -> StatementGraphState.Record {
        StatementGraphState.Record(id: id, kind: kind, label: label, statementLaTeX: "$x$",
                                   createdAt: now.addingTimeInterval(offset), author: nil, own: own, uses: uses)
    }

    @Test("Statements come in one order, whatever order the store gives")
    func deterministicOrder() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let records = [record(a, "Lem 2", own: .sketched, at: 1), record(b, "Lem 1", own: .sketched, at: 1),
                       record(c, "Thm 1", kind: .theorem, own: .proposed, at: 0)]
        let first = StatementGraphState(records: records, pinnedID: c)
        let second = StatementGraphState(records: records.reversed(), pinnedID: c)
        #expect(first.nodes.map(\.label) == ["Thm 1", "Lem 1", "Lem 2"])
        #expect(first == second)
    }

    @Test("Invariant 5: adopted lemmas leave out the theorem, conjectures and refuted statements")
    func adopted() {
        let (thm, lem, claim, conj, refuted, other) = (UUID(), UUID(), UUID(), UUID(), UUID(), UUID())
        let state = StatementGraphState(records: [
            record(thm, "Thm 1", kind: .theorem, own: .proposed, uses: [lem]),
            record(lem, "Lem 1", own: .humanChecked, at: 1),
            record(claim, "Claim 1", kind: .claim, own: .sketched, at: 2),
            record(conj, "Conj", kind: .conjecture, own: .proposed, at: 3),
            record(refuted, "Claim 2", kind: .claim, own: .refuted, at: 4),
            record(other, "Thm 2", kind: .theorem, own: .sketched, at: 5),
        ], pinnedID: thm)
        #expect(state.adoptedLemmas.map(\.label) == ["Lem 1", "Claim 1", "Thm 2"])
        #expect(state.refutedClaims.map(\.label) == ["Claim 2"])
        #expect(state.pinned?.label == "Thm 1")
        #expect(state[lem]?.usedBy == [thm])
    }

    @Test("Invariant 13: the status is explained in words, for people and for models")
    func explanations() {
        let (lem3, lem5, claim, lem6, lem7) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let state = StatementGraphState(records: [
            record(lem3, "Lem 3", own: .modelChecked),
            record(lem5, "Lem 5", own: .formallyVerified, uses: [lem3], at: 1),
            record(claim, "Claim", kind: .claim, own: .refuted, at: 2),
            record(lem6, "Lem 6", own: .humanChecked, uses: [claim], at: 3),
            record(lem7, "Lem 7", own: .humanChecked, uses: [lem6], at: 4),
        ], pinnedID: nil)
        #expect(state[lem5]?.contextNote == "checked by a model; capped by Lem 3 (checked by a model)")
        #expect(state[lem6]?.contextNote == "sketched; capped by Claim (refuted); depends on a refuted claim: Claim")
        #expect(state[lem7]?.contextNote == "sketched; capped by Lem 6 (sketched); depends on a refuted claim through Lem 6")
        #expect(state[lem3]?.contextNote == "checked by a model")
        #expect(state[lem7]?.accessibilityDescription == "Lem 7, lemma. Sketched. Capped by Lem 6 (sketched). Depends on a refuted claim through Lem 6. Uses Lem 6.")
        #expect(state[lem6]?.accessibilityDescription.hasSuffix("Uses Claim. Used by Lem 7.") == true)
        #expect(state[lem5]?.contextNote.contains("checked by a person") == false)
    }

    @Test("Sources read as attempt letter and step range")
    func sources() {
        let (attemptA, attemptB) = (UUID(), UUID())
        let slotA = Author.model(ModelSlotID(UUID())), slotB = Author.model(ModelSlotID(UUID()))
        var node = StatementNode(id: UUID(), kind: .lemma, label: "Lem 3", statementLaTeX: "", createdAt: now,
                                 derived: DerivedStatus(own: .sketched, displayed: .sketched))
        node.sources = [3, 4, 5].map { StatementNode.Source(stepID: UUID(), attemptID: attemptA, attemptAuthor: slotA,
                                                             index: $0, confidence: $0 == 5 ? .delicate : .routine) }
            + [StatementNode.Source(stepID: UUID(), attemptID: attemptB, attemptAuthor: slotB, index: 2, confidence: .routine)]
        #expect(node.sourceSummary { $0 == slotA ? "A" : "B" } == "A·3–5, B·2")
        #expect(node.delicateSources.map(\.index) == [5])
    }

    @Test("Candidates to use exclude whatever would close a cycle")
    func candidates() {
        let (thm, lem1, lem2) = (UUID(), UUID(), UUID())
        let state = StatementGraphState(records: [
            record(thm, "Thm 1", kind: .theorem, own: .proposed, uses: [lem1]),
            record(lem1, "Lem 1", own: .sketched, uses: [lem2], at: 1),
            record(lem2, "Lem 2", own: .sketched, at: 2),
        ], pinnedID: thm)
        #expect(state.candidates(toUse: lem2).isEmpty)
        #expect(state.candidates(toUse: thm).map(\.label) == ["Lem 2"])
    }
}

@Suite("Promotion draft")
struct PromotionDraftTests {
    private let texts = [1: "First.", 2: " Second. ", 3: "Third."]

    @Test("The statement starts as the steps' text until a person writes it")
    func prefill() {
        var draft = PromotionDraft(attemptID: UUID(), first: 2, last: 1, existingLabels: ["Lem 4"], texts: texts)
        #expect(draft.run == 1...2)
        #expect(draft.statementLaTeX == "First. Second.")
        #expect(draft.label == "Lem 5")
        draft.chooseRun(first: 3, last: 3, texts: texts)
        #expect(draft.statementLaTeX == "Third.")
        draft.editText("If $x$, then $y$.")
        draft.chooseRun(first: 1, last: 3, texts: texts)
        #expect(draft.statementLaTeX == "If $x$, then $y$.")
    }

    @Test("Choosing another kind relabels until a person types a label")
    func kind() {
        var draft = PromotionDraft(attemptID: UUID(), first: 1, last: 1, existingLabels: ["Claim"], texts: texts)
        draft.chooseKind(.claim, existingLabels: ["Claim"])
        #expect(draft.label == "Claim 2")
        draft.editLabel("Key claim")
        draft.chooseKind(.lemma, existingLabels: ["Claim"])
        #expect(draft.label == "Key claim")
        #expect(draft.kind == .lemma)
    }
}
