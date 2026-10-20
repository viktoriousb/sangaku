import Foundation
import Testing
@testable import sangaku

/// Hand-built attempts for the pure comparison rules.
private enum Make {
    static func step(_ index: Int, _ establishes: String, text: String? = nil, revision: UUID? = UUID()) -> AlignedStep {
        AlignedStep(id: UUID(), index: index, establishes: establishes, text: text ?? "Step \(index): \(establishes).",
                    revisionID: revision)
    }

    static func attempt(_ labels: [String]) -> AlignedAttempt {
        AlignedAttempt(id: UUID(), steps: labels.enumerated().map { step($0.offset + 1, $0.element) })
    }

    static func row(_ a: AlignedStep?, _ b: AlignedStep?, _ verdict: String, note: String? = nil,
                    phrases: (String?, String?) = (nil, nil), label: String = "") -> AlignmentRow {
        AlignmentRow(stepAID: a?.id, stepBID: b?.id, label: label, verdict: verdict, note: note,
                     keyPhraseA: phrases.0, keyPhraseB: phrases.1, revisionAID: a?.revisionID, revisionBID: b?.revisionID)
    }

    static func correction(_ action: AlignmentCorrection.Action, _ a: AlignedStep, _ b: AlignedStep,
                           verdict: String? = nil, at seconds: Double = 0) -> AlignmentCorrection {
        AlignmentCorrection(action: action, stepAID: a.id, stepBID: b.id, verdict: verdict,
                            revisionAID: a.revisionID, revisionBID: b.revisionID, personID: UUID(),
                            at: Date(timeIntervalSinceReferenceDate: seconds))
    }

    static func state(_ first: AlignedAttempt, _ second: AlignedAttempt, model: [AlignmentRow]? = nil,
                      corrections: [AlignmentCorrection] = []) -> ComparisonState {
        ComparisonState(ComparisonFacts(first: first, second: second, modelRows: model, corrections: corrections))
    }
}

@Suite("Compare: pairing by label")
struct LabelPairingTests {
    @Test("Steps pair by what they establish, the k-th with the k-th, and are never judged by it")
    func pairsByLabel() {
        let first = Make.attempt(["Sylow counts", "q > p", "Order 12 case"])
        let second = Make.attempt(["  sylow   COUNTS ", "q>p", "q > p"])
        let state = Make.state(first, second)
        let paired = state.rows.filter { $0.a != nil && $0.b != nil }
        #expect(paired.map { [$0.a!.index, $0.b!.index] } == [[1, 1], [2, 3]])
        #expect(paired.allSatisfy { $0.state == .notCompared && $0.judgedBy == .none && $0.verdict == nil })
        #expect(state.rows.filter { $0.state == .onlyOne }.count == 2, "Order 12 case and q>p stand alone")
        #expect(!state.hasModelRows)
    }

    @Test("Steps with no label are never paired by label")
    func emptyLabels() {
        let state = Make.state(Make.attempt([""]), Make.attempt([" "]))
        #expect(state.rows.count == 2 && state.rows.allSatisfy { $0.state == .onlyOne })
    }

    @Test("A step only in the second attempt follows the row of its nearest earlier step")
    func order() {
        let first = Make.attempt(["a", "b", "c"])
        let second = Make.attempt(["a", "extra", "c"])
        let state = Make.state(first, second)
        #expect(state.rows.map { [$0.a?.index ?? 0, $0.b?.index ?? 0] } == [[1, 1], [0, 2], [2, 0], [3, 3]])
    }
}

@Suite("Compare: the model's rows and a person's corrections")
struct ComparisonMergeTests {
    private let first = Make.attempt(["Sylow counts", "q > p", "Resolve q | p + 1", "Order 12 case"])
    private let second = Make.attempt(["Sylow counts", "q > p", "Resolve q | p + 1"])

    private var a: [AlignedStep] { first.steps }
    private var b: [AlignedStep] { second.steps }

    @Test("The model's rows are read as judged, on the revisions it saw")
    func modelRows() {
        let state = Make.state(first, second, model: [
            Make.row(a[0], b[0], "equivalent"), Make.row(a[1], b[1], "equivalent"),
            Make.row(a[2], b[2], "diverge", note: "B is false at (2, 3)", phrases: ("Resolve", "q | p")),
            Make.row(a[3], nil, "onlyA"),
        ])
        #expect(state.rows.map(\.state) == [.equivalent, .equivalent, .diverge, .onlyOne])
        #expect(state.rows.map(\.judgedBy) == [.model, .model, .model, .model])
        #expect(state.rows[2].note == "B is false at (2, 3)")
        #expect(state.rows[2].markA == 8..<15, "\"Resolve\" in \"Step 3: Resolve q | p + 1.\"")
        #expect(state.summary == CompareSummary(state.rows) && state.summary.equivalent == 2 && state.summary.diverge == 1)
    }

    @Test("Fail closed: unknown steps, reused steps, empty rows and odd verdicts")
    func sanitised() {
        let ghost = Make.step(9, "ghost")
        let state = Make.state(first, second, model: [
            Make.row(ghost, b[0], "equivalent"),          // a step that is not in the attempt: dropped
            Make.row(a[0], b[1], "nonsense"),             // unknown verdict: diverge
            Make.row(a[1], b[1], "equivalent"),           // b[1] already used: dropped
            Make.row(nil, nil, "equivalent"),             // no step: dropped
            Make.row(a[2], b[2], "onlyA"),                // a pair called one-sided: diverge
            Make.row(a[3], nil, "equivalent"),            // one side called equivalent: only one
        ])
        #expect(state[row: RowKey(a: a[0].id, b: b[1].id)]?.state == .diverge)
        #expect(state[row: RowKey(a: a[2].id, b: b[2].id)]?.state == .diverge)
        #expect(state[row: RowKey(a: a[3].id, b: nil)]?.state == .onlyOne)
        // a[1] and b[0] were in dropped rows; they fall back to the label pairing, unjudged.
        #expect(state[row: RowKey(a: a[1].id, b: nil)]?.state == .onlyOne)
        #expect(state[row: RowKey(a: nil, b: b[0].id)]?.state == .onlyOne)
    }

    @Test("A person's corrections win over the model's rows, and survive a new model alignment")
    func corrections() {
        let corrections = [
            Make.correction(.unpair, a[0], b[0]),
            Make.correction(.pair, a[3], b[2]),
            Make.correction(.judge, a[3], b[2], verdict: "equivalent"),
            Make.correction(.judge, a[1], b[1], verdict: "diverge"),
        ]
        for model in [
            [Make.row(a[0], b[0], "equivalent"), Make.row(a[1], b[1], "equivalent"), Make.row(a[2], b[2], "diverge")],
            [Make.row(a[1], b[1], "equivalent"), Make.row(a[2], b[2], "equivalent"), Make.row(a[3], nil, "onlyA")],
        ] {
            let state = Make.state(first, second, model: model, corrections: corrections)
            #expect(state[row: RowKey(a: a[0].id, b: b[0].id)] == nil, "separated by the person")
            #expect(state[row: RowKey(a: a[0].id, b: nil)]?.judgedBy == .person)
            #expect(state[row: RowKey(a: a[3].id, b: b[2].id)]?.state == .equivalent)
            #expect(state[row: RowKey(a: a[3].id, b: b[2].id)]?.judgedBy == .person)
            #expect(state[row: RowKey(a: a[1].id, b: b[1].id)]?.state == .diverge, "the person's verdict wins")
            #expect(state[row: RowKey(a: a[2].id, b: nil)]?.state == .onlyOne, "its partner went to step 4")
        }
    }

    @Test("Clearing a judgement returns the row to the model's verdict; corrections on unknown steps are ignored")
    func clearAndIgnore() {
        let ghost = Make.step(9, "ghost")
        let state = Make.state(first, second, model: [Make.row(a[0], b[0], "equivalent")], corrections: [
            Make.correction(.judge, a[0], b[0], verdict: "diverge"),
            Make.correction(.clear, a[0], b[0]),
            Make.correction(.pair, ghost, b[1]),
        ])
        #expect(state.rows.first?.state == .equivalent && state.rows.first?.judgedBy == .model)
        #expect(state[row: RowKey(a: a[1].id, b: b[1].id)]?.state == .notCompared, "the ghost's pairing changed nothing")
    }

    @Test("Separating two steps, or pairing either with another, withdraws the person's judgement of them")
    func separationClears() {
        let key = RowKey(a: a[1].id, b: b[1].id)
        let judged = Make.correction(.judge, a[1], b[1], verdict: "equivalent", at: 1)
        let separated = Make.state(first, second, corrections: [
            judged, Make.correction(.unpair, a[1], b[1], at: 2), Make.correction(.pair, a[1], b[1], at: 3),
        ])
        #expect(separated[row: key]?.judgedBy == RowJudge.none && separated[row: key]?.state == .notCompared)
        let elsewhere = Make.state(first, second, corrections: [
            judged, Make.correction(.pair, a[1], b[2], at: 2), Make.correction(.pair, a[1], b[1], at: 3),
        ])
        #expect(elsewhere[row: key]?.judgedBy == RowJudge.none, "re-pairing step 2 elsewhere separated it too")
        let kept = Make.state(first, second, corrections: [judged, Make.correction(.pair, a[1], b[1], at: 2)])
        #expect(kept[row: key]?.judgedBy == .person, "pairing a pair again separates nothing")
    }

    @Test("Invariant 2: a judgement on an older revision is out of date, never equivalent, and loses its marks")
    func staleness() {
        var revised = second
        revised.steps[0].revisionID = UUID()
        revised.steps[2].revisionID = UUID()
        let state = Make.state(first, revised, model: [
            Make.row(a[0], second.steps[0], "equivalent"),
            Make.row(a[2], second.steps[2], "diverge", phrases: ("Resolve", "Resolve")),
        ])
        #expect(state.rows[0].state == .stale && state.rows[0].verdict == .equivalent)
        #expect(state.rows[2].state == .stale && state.rows[2].markA == nil)
        #expect(state.summary.equivalent == 0 && state.summary.stale == 2)
        var unrecorded = Make.row(a[1], b[1], "equivalent")
        unrecorded.revisionBID = nil
        #expect(Make.state(first, second, model: [unrecorded]).rows[1].state == .stale, "an unrecorded revision covers nothing")
        let person = Make.correction(.judge, a[1], b[1], verdict: "equivalent")
        #expect(Make.state(first, revised, corrections: [person]).rows[1].state == .equivalent)
        var later = revised
        later.steps[1].revisionID = UUID()
        #expect(Make.state(first, later, corrections: [person]).rows[1].state == .stale)
    }

    @Test("Invariant 2: a model's \"no counterpart\" goes out of date when its step is revised; a person's does not")
    func staleSingles() {
        var revised = first
        revised.steps[3].revisionID = UUID()
        let model = [Make.row(a[3], nil, "onlyA", note: "Only Attempt 1 treats order 12")]
        let current = Make.state(first, second, model: model)
        #expect(current.rows[3].state == .onlyOne && current.rows[3].note == "Only Attempt 1 treats order 12")
        let stale = Make.state(revised, second, model: model)
        #expect(stale.rows[3].state == .stale && stale.rows[3].note == nil && stale.staleRowIDs == [stale.rows[3].id])
        #expect(CompareWording.judged(stale.rows[3]) == "no counterpart, by a model; the step changed since")
        let separated = Make.state(revised, second, corrections: [Make.correction(.unpair, a[3], b[2])])
        #expect(separated[row: RowKey(a: a[3].id, b: nil)]?.state == .onlyOne)
    }

    @Test("Invariant 2: an out-of-date model reading lends no note or marks, even to a row a person judged now")
    func staleModelText() {
        var revised = second
        revised.steps[2].revisionID = UUID()
        let model = [Make.row(a[2], b[2], "diverge", note: "Attempt 2 is false at (2, 3)", phrases: ("Resolve", "Resolve"))]
        let person = Make.correction(.judge, a[2], revised.steps[2], verdict: "diverge")
        let row = Make.state(first, revised, model: model, corrections: [person]).rows[2]
        #expect(row.state == .diverge && row.judgedBy == .person)
        #expect(row.note == nil && row.markA == nil && row.markB == nil)
        let current = Make.state(first, second, model: model, corrections: [Make.correction(.judge, a[2], b[2], verdict: "diverge")])
        #expect(current.rows[2].note != nil && current.rows[2].markA != nil, "a current reading keeps both")
    }

    @Test("Unreadable stored layers fall back to the label pairing")
    func unreadable() {
        let state = ComparisonState(ComparisonFacts(first: first, second: second,
                                                    modelRows: [Make.row(a[0], b[0], "equivalent")],
                                                    modelRowsUnreadable: true, correctionsUnreadable: true))
        #expect(state.rows.allSatisfy { $0.judgedBy == .none } && state.modelRowsUnreadable)
    }

    @Test("Differences only hides just the rows judged equivalent now")
    func filter() {
        var revised = second
        revised.steps[1].revisionID = UUID()
        let state = Make.state(first, revised, model: [Make.row(a[0], b[0], "equivalent"), Make.row(a[1], b[1], "equivalent")])
        #expect(state.visibleRows(.differences).map(\.state) == [.stale, .notCompared, .onlyOne])
        #expect(state.visibleRows(.all).count == 4)
    }

    @Test("Every step of both attempts is in exactly one row, whatever the stored layers say (200 random cases)")
    func totality() {
        var random = SeededGenerator(state: 11)
        let labels = ["a", "b", "c", "d", ""]
        for _ in 0..<200 {
            let first = Make.attempt((0..<Int.random(in: 0...6, using: &random)).map { _ in labels.randomElement(using: &random)! })
            let second = Make.attempt((0..<Int.random(in: 0...6, using: &random)).map { _ in labels.randomElement(using: &random)! })
            let pool: [AlignedStep?] = first.steps + second.steps + [nil, Make.step(9, "ghost")]
            let model = (0..<Int.random(in: 0...6, using: &random)).map { _ in
                Make.row(pool.randomElement(using: &random)!, pool.randomElement(using: &random)!,
                         ["equivalent", "diverge", "onlyA", "onlyB", "?"].randomElement(using: &random)!)
            }
            var corrections: [AlignmentCorrection] = []
            if let x = first.steps.randomElement(using: &random), let y = second.steps.randomElement(using: &random) {
                corrections.append(Make.correction(AlignmentCorrection.Action.allCases.randomElement(using: &random)!, x, y,
                                                   verdict: "equivalent"))
            }
            let state = Make.state(first, second, model: model, corrections: corrections)
            #expect(state.rows.compactMap(\.a?.id).sorted { $0.uuidString < $1.uuidString }
                    == first.steps.map(\.id).sorted { $0.uuidString < $1.uuidString })
            #expect(state.rows.compactMap(\.b?.id).sorted { $0.uuidString < $1.uuidString }
                    == second.steps.map(\.id).sorted { $0.uuidString < $1.uuidString })
            #expect(state.rows.allSatisfy { $0.a != nil || $0.b != nil })
            let counts = state.summary
            #expect(counts.equivalent + counts.diverge + counts.onlyOne + counts.notCompared + counts.stale == state.rows.count)
            if let pair = corrections.first, pair.action == .pair {
                #expect(state[row: pair.key] != nil, "a person's pair always appears")
            }
            if let separated = corrections.first, separated.action == .unpair {
                #expect(state[row: separated.key] == nil, "a separated pair never does")
            }
        }
    }
}

@Suite("Compare: key phrases, sides and blind mode")
struct CompareBlindTests {
    @Test("A key phrase is found in the current text, by UTF-16 offsets, or dropped")
    func keyPhrase() {
        #expect(KeyPhrase.locate("q = p + 1", in: "forces q = p + 1, so") == 7..<16)
        #expect(KeyPhrase.locate("ℤ", in: "in 𝔽 and ℤ") == 10..<11, "𝔽 takes two UTF-16 units")
        #expect(KeyPhrase.locate("absent", in: "text") == nil)
        #expect(KeyPhrase.locate("  ", in: "text") == nil && KeyPhrase.locate(nil, in: "text") == nil)
        #expect(KeyPhrase.locate("cafe\u{301} q", in: "le caf\u{E9} q") == 3..<9,
                "the mark spans the text's own é, one UTF-16 unit, not the phrase's two")
    }

    @Test("Invariant 9: which attempt is first follows the IDs alone: symmetric, stable and about even")
    func sideOrder() {
        var firsts = 0
        var random = SeededGenerator(state: 3)
        for _ in 0..<200 {
            let x = UUID(uuid: (UInt8.random(in: 0...255, using: &random), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
                                UInt8.random(in: 0...255, using: &random)))
            let y = UUID()
            let order = SideOrder.orient(x, y)
            #expect(order == SideOrder.orient(y, x))
            #expect(Set([order.first, order.second]) == [x, y])
            if order.first == x { firsts += 1 }
        }
        #expect((60...140).contains(firsts))
    }

    @Test("Invariant 9: authors stay hidden while blind until a verdict is recorded")
    func hides() {
        #expect(CompareBlind.hides(windowBlind: true, verdictRecorded: false))
        #expect(!CompareBlind.hides(windowBlind: true, verdictRecorded: true))
        #expect(!CompareBlind.hides(windowBlind: false, verdictRecorded: false))
    }

    @Test("Invariant 9: notes naming a model, a slot or a provider are withheld while blind; mathematics passes")
    func shield() {
        let words = BlindShield.Vocabulary(letters: ["A", "B", "C"], names: ["Claude Opus 5.5", "claude-opus-5-5", "Anthropic"])
        for unsafe in ["Model B is false at (2, 3)", "A's step 5 is right", "as model C says", "slot A",
                       "claude opus 5.5 wrote this", "the anthropic model", "Referee C disagrees"] {
            #expect(!BlindShield.isSafe(unsafe, words), "\(unsafe)")
        }
        for safe in ["Attempt 2 is false at $(p, q) = (2, 3)$", "$A \\subseteq B$", "the group A acts on B",
                     "q cannot divide p + 1", "Sylow counts"] {
            #expect(BlindShield.isSafe(safe, words), "\(safe)")
        }
    }
}

@Suite("Compare: choices")
struct CompareChoiceTests {
    private func option(_ minute: Double, fanOut: UUID? = nil) -> AttemptOption {
        AttemptOption(id: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: minute * 60), author: nil,
                            stepCount: 3, isPartial: false, standingOutcome: nil, fanOutID: fanOut)
    }

    @Test("The pair: picked, else named, else the latest fan-out's first two, else the two newest")
    func pair() {
        let early = UUID(), late = UUID()
        let e1 = option(1, fanOut: early), e2 = option(2, fanOut: early)
        let l1 = option(3, fanOut: late), l2 = option(4, fanOut: late), lone = option(5)
        let options = [e1, e2, l1, l2, lone]
        func resolve(_ selection: CompareSelection) -> [UUID]? {
            ComparePairChoice.resolve(selection, among: options).map { [$0.0, $0.1] }
        }
        #expect(resolve(CompareSelection(picked: [lone.id, e1.id])) == [lone.id, e1.id])
        #expect(resolve(CompareSelection(picked: [lone.id, UUID()], candidateAttemptIDs: [e2.id, e1.id])) == [e2.id, e1.id])
        #expect(resolve(CompareSelection()) == [l1.id, l2.id])
        #expect(ComparePairChoice.resolve(CompareSelection(), among: [option(1), option(2), option(3)]).map { [$0.0, $0.1] }?.count == 2)
        #expect(ComparePairChoice.resolve(CompareSelection(), among: [e1]) == nil)
    }

    @Test("The aligner is the fan-out's referee, else the only referee, else the person chooses; never an author")
    func aligner() {
        let referee = UUID(), other = UUID(), author = UUID()
        #expect(AlignerChoice.resolve(sharedFanOutReferee: referee, refereeSlots: [referee, other], authors: []) == .slot(referee))
        #expect(AlignerChoice.resolve(sharedFanOutReferee: nil, refereeSlots: [other], authors: []) == .slot(other))
        #expect(AlignerChoice.resolve(sharedFanOutReferee: nil, refereeSlots: [referee, other], authors: []) == .choose([referee, other]))
        #expect(AlignerChoice.resolve(sharedFanOutReferee: author, refereeSlots: [author], authors: [author]) == AlignerChoice.none)
    }

    @Test("Four columns from 680 points of content, cards below")
    func layout() {
        #expect(CompareLayoutMode.resolve(width: 252) == .stacked)
        #expect(CompareLayoutMode.resolve(width: 679) == .stacked)
        #expect(CompareLayoutMode.resolve(width: 680) == .table)
    }

    @Test("The thread collapses runs of two or more steps matching now, and finds the first divergence")
    func thread() {
        let first = Make.attempt(["a", "b", "c", "d", "e"])
        let second = Make.attempt(["a", "b", "c", "d", "e"])
        var revised = second
        revised.steps[3].revisionID = UUID()
        let state = Make.state(first, revised, model: [
            Make.row(first.steps[0], second.steps[0], "equivalent"), Make.row(first.steps[1], second.steps[1], "equivalent"),
            Make.row(first.steps[2], second.steps[2], "diverge"), Make.row(first.steps[3], second.steps[3], "equivalent"),
            Make.row(first.steps[4], second.steps[4], "equivalent"),
        ])
        #expect(ThreadAgreement.collapsedRuns(state.rows, side: .second) == [1...2], "step 4 is out of date; 5 alone")
        #expect(ThreadAgreement.collapsedRuns(state.rows, side: .second, keepOpen: [2]) == [], "a flagged step stays open")
        #expect(ThreadAgreement.firstDivergence(state.rows)?.b?.index == 3)
    }
}
