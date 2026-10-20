import AppKit
import SwiftData
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import sangaku

@Suite("Compare: what it says and how it looks")
struct CompareWordingTests {
    private let fixture = PreviewFixtures.make()

    private var authors: AuthorDirectory {
        AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
    }
    private var state: ComparisonState {
        ComparisonState.read(fixture.attemptA, fixture.attemptB, in: fixture.problem, people: fixture.state.problems.personIDs())
    }

    private func identity(hidden: Bool) -> CompareIdentity {
        CompareIdentity.read(state, of: fixture.attemptA, fixture.attemptB, in: fixture.problem, windowBlind: hidden,
                             choice: .slot(fixture.slotC.stableID), people: [fixture.you, fixture.mk], catalog: .standard)
    }

    @Test("Invariant 3: row states differ in glyph and words, never only in colour; a model's equivalence is never a check")
    func styles() {
        let states: [RowState] = [.equivalent, .diverge, .onlyOne, .notCompared, .stale]
        let styles = states.map { CompareRowStyle.style(for: $0) }
        #expect(Set(styles.map(\.glyph)).count == states.count && Set(styles.map(\.label)).count == states.count)
        #expect(styles.allSatisfy { $0.isProvisional }, "no row is drawn as checked")
        #expect(styles[0].glyph != "✓" && styles[0].ink != .ink)
        #expect(!styles.map(\.label).contains(StatusStyle.style(for: .refuted).label), "a divergence is never a refutation")
        #expect(CompareRowStyle.style(for: .onlyOne, side: 2).label == "Only in Attempt 2")
    }

    @Test("The example's summary, who decided each row, and the thread's words")
    func words() throws {
        let state = state
        #expect(CompareWording.chips(state.summary).map(\.label) == ["4 rows equivalent", "1 divergence", "1 step with no match"])
        #expect(state.rows.prefix(4).allSatisfy { CompareWording.judged($0) == "judged by a model" })
        #expect(CompareWording.judged(state.rows[5]) == "no counterpart, by a model")
        #expect(CompareWording.matchRun(1...4, other: "A") == "Steps 1–4 match A's")
        let diverging = try #require(ThreadAgreement.firstDivergence(state.rows))
        #expect(CompareWording.divergence(diverging) == "The attempts part ways at “Resolve q | p + 1”.")
        #expect(CompareWording.status(hasModelRows: false, alignedAt: nil, aligner: "Model C")
                == "Paired by what the steps establish; not compared yet.")
        #expect(CompareWording.holds(.neither) == "Neither holds")
        #expect(CompareWording.recorded(nil, at: nil) == "Recorded: a verdict this version cannot read")
        #expect(CompareWording.storedNothing(.failed(kind: "overloaded", message: "Overloaded."))
                == "The last alignment stored nothing: Overloaded. The earlier rows are kept.")
    }

    @Test("Invariant 9: while hidden, nothing Compare says names a model, a slot or who wrote which attempt")
    func blindLeaks() throws {
        let hidden = identity(hidden: true)
        #expect(hidden.hidden && hidden.first == nil && hidden.second == nil)
        #expect(hidden.firstSlotID == nil && hidden.secondSlotID == nil && hidden.referee == nil)
        #expect(hidden.aligners == [fixture.slotC.stableID: "the referee"])
        let state = state
        let run = CompareRunInfo.read(fixture.alignment, live: [:], identity: hidden)
        let options = AttemptOption.make(messages: fixture.mainBranch.sortedMessages, live: [])
        var shown = [hidden.title(1), hidden.title(2), CompareWording.title, CompareWording.subtitle, run.alignerName,
                     CompareWording.status(hasModelRows: true, alignedAt: nil, aligner: run.alignerName), run.summary,
                     hidden.alignerName(fixture.slotC.stableID)]
        shown += options.map(hidden.attemptLabel) + hidden.aligners.values
        shown += CompareWording.chips(state.summary).map(\.label)
        for row in state.rows {
            shown += [hidden.label(row), CompareWording.judged(row), CompareWording.verdict(row).label]
            shown += [hidden.shielded(row.note), CompareWording.partsAt(row.phrase(1)), CompareWording.partsAt(row.phrase(2))]
                .compactMap { $0 }
        }
        let blockers: [SendBlocker] = [
            .missingKey(providerName: "Anthropic"), .providerNotAllowed(providerID: "anthropic", providerName: "Anthropic"),
            .slotCannotReceive(letter: "C", role: .prover), .noProvider("anthropic"), .compare(.noAligner),
            .recipient(letter: "C", .attemptsUnfinished([])),
        ]
        shown += blockers.map(hidden.reason)
        for text in shown {
            for name in ["Model A", "Model B", "Model C", "A's", "B's", "Claude", "Opus", "Anthropic", "anthropic"] {
                #expect(!text.contains(name), "\"\(text)\" names \(name)")
            }
        }
        #expect(hidden.shielded("Model B's step 5 is false") == CompareIdentity.withheldNote)
        let shown2 = identity(hidden: false)
        #expect(!shown2.hidden && shown2.title(1).hasPrefix("Attempt 1 · Model "))
        #expect(shown2.shielded("Model B's step 5 is false") == "Model B's step 5 is false")
        #expect(shown2.referee == CompareReferee(id: fixture.slotC.stableID, name: "Model C"))
        #expect(shown2.reason(.missingKey(providerName: "Anthropic")) == "No Anthropic API key is stored.")
    }

    @Test("Invariant 9: a label, an error or a summary the model wrote is withheld while blind when it names one")
    func blindModelText() throws {
        let hidden = identity(hidden: true)
        var row = try #require(state.rows.first)
        row.label = "Model B's lemma"
        #expect(hidden.label(row) == row.a?.establishes && identity(hidden: false).label(row) == "Model B's lemma")
        row.a?.establishes = "A's count"
        row.b?.establishes = "as Claude says"
        #expect(hidden.label(row) == "Label hidden while blind")

        fixture.alignment.modelSummary = "Model A is right."
        let record = RequestRecord()
        record.createdAt = .now
        record.finishedAt = .now
        record.errorKind = "not_found"
        record.errorMessage = "model: claude-opus-5-5 not found"
        fixture.state.container.mainContext.insert(record)
        record.alignment = fixture.alignment
        let blind = CompareRunInfo.read(fixture.alignment, live: [:], identity: hidden)
        #expect(blind.lastProblem == CompareWording.storedNothingWithheld)
        #expect(blind.summary == CompareIdentity.withheldNote && blind.alignerName == "the referee")
        let open = CompareRunInfo.read(fixture.alignment, live: [:], identity: identity(hidden: false))
        #expect(open.lastProblem?.contains("claude-opus-5-5") == true && open.summary == "Model A is right.")
        #expect(open.alignerName == "Model C")
    }

    @Test("Invariant 9: Compare stays blind until a verdict is stored, readable or not, and then names the authors")
    func blindAssembly() throws {
        #expect(identity(hidden: true).hidden)
        try fixture.state.alignments.recordHolds(.first, in: state.pair)
        #expect(!identity(hidden: true).hidden)
        fixture.alignment.holdsRaw = "maybe"
        #expect(!identity(hidden: true).hidden, "a verdict this version cannot read was still recorded")
        let run = CompareRunInfo.read(fixture.alignment, live: [:], identity: identity(hidden: true))
        #expect(run.holdsRecorded && run.holds == nil)
    }

    @Test("Requests about a row name the steps and the models once shown")
    func requests() throws {
        let identity = identity(hidden: false)
        let row = try #require(ThreadAgreement.firstDivergence(state.rows))
        let repair = try #require(CompareWording.repairRequest(row, side: 2, identity: identity))
        #expect(repair.contains("your step 5 of Attempt 2 · Model") && repair.contains("Repair your step 5"))
        #expect(CompareWording.refereeRequest(row, identity: identity).contains("Which of these holds"))
        let only = state.rows[5]
        let side = only.a != nil ? 1 : 2
        #expect(CompareWording.repairRequest(only, side: side, identity: identity)?.contains("no matching step") == true)
    }

    @Test("A dragged step pairs with the row's step of the other attempt; it travels as its own type, never as text")
    func drag() throws {
        let row = state.rows[0]
        let otherSecond = try #require(state.rows[1].b)
        #expect(StepDrag(side: 2, step: otherSecond.id).pairing(onto: row) == RowKey(a: row.a?.id, b: otherSecond.id))
        #expect(StepDrag(side: 2, step: try #require(row.b).id).pairing(onto: row) == nil)
        #expect(StepDrag(side: 1, step: try #require(row.a).id).pairing(onto: row) == nil)
        let drag = StepDrag(side: 1, step: UUID())
        #expect(try JSONDecoder().decode(StepDrag.self, from: JSONEncoder().encode(drag)) == drag)
        #expect(UTType.sangakuStep.conforms(to: .data) && !UTType.sangakuStep.conforms(to: .text))
    }

    @Test("Invariant 16: a key phrase is marked, and spelled out, only where it leaves every formula whole")
    func markPieces() {
        let source = "Since $q > p$, we get $q = p + 1$. Of"
        let phrase = "we get $q = p + 1$"
        let mark = KeyPhrase.locate(phrase, in: source)
        #expect(MathTextComposer.pieces(source, mark: mark)?.map(\.0) == ["Since $q > p$, ", phrase, ". Of"])
        #expect(KeyPhrase.locate("q = p", in: source) == nil, "inside a formula")
        #expect(MathTextComposer.pieces(source, mark: 23..<28) == nil, "it would cut a formula")
        #expect(KeyPhrase.locate("p$, we get $q", in: source) == nil, "it would swap prose and math")
        #expect(KeyPhrase.locate(#"(q > p\), we"#, in: #"Since \(q > p\), we get"#) == nil, "it would cut \\( from its formula")
        #expect(KeyPhrase.locate(#"q \nmid p + 1"#, in: #"so $q \nmid p + 1$."#) == nil)
        #expect(MathTextComposer.pieces("see $$x$$ here", mark: 4..<9) == nil, "no displayed formula inside a mark")
        #expect(MathTextComposer.pieces(source, mark: nil) == nil && MathTextComposer.pieces(source, mark: 0..<0) == nil)
        let row = CompareRow(id: RowKey(a: nil, b: nil), a: AlignedStep(id: UUID(), index: 1, establishes: "", text: source),
                             b: nil, label: "", state: .diverge, judgedBy: .model, markA: KeyPhrase.locate(phrase, in: source))
        #expect(CompareWording.partsAt(row.phrase(1)) == "Where they part: \(phrase)")
    }

    @Test("The thread: B's steps 1–4 collapse to match A's, and the banner names the row where they part")
    func thread() throws {
        let agreement = try #require(FanOutAgreement.read(attempts: [fixture.messageA, fixture.messageB], problem: fixture.problem,
                                                          live: [:], authors: authors))
        #expect(agreement.matches[fixture.messageB.stableID] == MatchedRuns(runs: [1...4], other: "A"))
        #expect(agreement.matches[fixture.messageA.stableID] == nil)
        #expect(agreement.divergence?.label == "Resolve q | p + 1")
        // A stopped comparison of nothing: no banner, no collapse.
        fixture.problem.alignments = []
        #expect(FanOutAgreement.read(attempts: [fixture.messageA, fixture.messageB], problem: fixture.problem,
                                     live: [:], authors: authors) == nil)
    }

    @Test("The thread never folds away a step that asks for attention")
    func threadKeepsFlagsOpen() throws {
        func runs() throws -> [ClosedRange<Int>]? {
            try #require(FanOutAgreement.read(attempts: [fixture.messageA, fixture.messageB], problem: fixture.problem,
                                              live: [:], authors: authors)).matches[fixture.messageB.stableID]?.runs
        }
        let steps = fixture.attemptB.sortedSteps
        steps[1].confidence = .delicate
        #expect(try runs() == [3...4], "a delicate step 2 ends the run; step 1 alone does not collapse")
        steps[1].confidence = .standard
        steps[2].confidence = .guess
        #expect(try runs() == [1...2])
        steps[2].confidence = .standard
        _ = try fixture.state.reviews.mark(.unclear, step: steps[1].stableID, revision: steps[1].latestRevision!.stableID)
        #expect(try runs() == [3...4], "an open objection keeps its step in view")
    }
}

@Suite("Compare: window state")
struct CompareWindowTests {
    @Test("Opening Compare, picking attempts, and a new problem starting over; the filter is kept; blind mode hides the model chrome")
    func window() {
        let window = WindowState()
        let ids = [UUID(), UUID()]
        window.compareFilter = .differences
        window.openCompare(CompareTarget(attemptIDs: ids))
        #expect(window.activeView == .compare && window.compare.candidateAttemptIDs == ids && window.compareFilter == .differences)
        window.focusCompare(row: RowKey(a: UUID(), b: nil))
        window.chooseCompare(ids.reversed())
        #expect(window.compare.picked == ids.reversed() && window.compareRow == nil)
        #expect(!window.hidesModelChrome)
        window.blindMode = true
        #expect(window.hidesModelChrome)
        window.activeView = .thread
        #expect(!window.hidesModelChrome, "blind mode applies to Compare")
        window.select(problem: nil)
        #expect(window.compare == CompareSelection() && window.compareRow == nil && window.compareFilter == .differences)
    }

    @Test("J and K move between rows, stopping at the ends, never while typing or with a modifier")
    func keys() {
        let rows = [RowKey(a: UUID(), b: nil), RowKey(a: UUID(), b: UUID()), RowKey(a: nil, b: UUID())]
        func move(_ key: String, from current: RowKey?, typing: Bool = false, shift: Bool = false) -> RowKey? {
            ListKeys.move(ListKeyInput(characters: key, shift: shift), isTyping: typing, from: current, in: rows)
        }
        #expect(move("j", from: nil) == rows[0] && move("k", from: nil) == rows[2])
        #expect(move("j", from: rows[0]) == rows[1] && move("J", from: rows[2]) == rows[2])
        #expect(move("k", from: rows[0]) == rows[0])
        #expect(move("j", from: rows[0], typing: true) == nil && move("j", from: rows[0], shift: true) == nil)
        #expect(move("x", from: rows[0]) == nil && ListKeys.move(ListKeyInput(characters: "j"), isTyping: false,
                                                                 from: nil, in: [RowKey]()) == nil)
    }
}

/// Rows outside Compare, as a test host.
private struct RowsHost: View {
    let state: ComparisonState
    let context: CompareRowContext
    let stacked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.rows) { row in
                let notice = row.id == state.rows[4].id ? CompareNotice(row: row.id, text: "Marked diverging", isError: false) : nil
                if stacked {
                    CompareStackedRow(row: row, context: context, isCurrent: row.id == state.rows[4].id, isActive: true,
                                      notice: notice)
                } else {
                    CompareTableRow(row: row, context: context, isCurrent: row.id == state.rows[4].id, isActive: true,
                                    notice: notice)
                }
            }
        }
    }
}

@Suite("Compare: layout and renders", .serialized)
struct CompareLayoutTests {
    private let fixture = PreviewFixtures.make()

    private func environment<V: View>(_ view: V) -> some View {
        view.appEnvironment(fixture.state)
            .environment(\.mathContext, fixture.mathContext)
            .modelContainer(fixture.state.container)
    }

    private func size<V: View>(of view: V, width: CGFloat) -> CGSize {
        NSHostingController(rootView: environment(view))
            .sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    private func parts(hidden: Bool = false) -> (ComparisonState, CompareRowContext, CompareIdentity) {
        let state = ComparisonState.read(fixture.attemptA, fixture.attemptB, in: fixture.problem,
                                         people: fixture.state.problems.personIDs())
        let identity = CompareIdentity.read(state, of: fixture.attemptA, fixture.attemptB, in: fixture.problem,
                                            windowBlind: hidden, choice: .slot(fixture.slotC.stableID),
                                            people: [fixture.you, fixture.mk], catalog: .standard)
        let context = CompareRowContext(pair: state.pair, first: state.first.steps, second: state.second.steps,
                                        firstIsPartial: false, secondIsPartial: hidden, identity: identity)
        return (state, context, identity)
    }

    @Test("Stacked rows and the resolve panel fit the narrowest workspace; the table fits where it is used")
    func fits() {
        let (state, context, identity) = parts()
        let narrow = WindowRoot.contentMinWidth - 2 * CompareScreen.padding
        #expect(size(of: RowsHost(state: state, context: context, stacked: true), width: narrow).width <= narrow)
        #expect(size(of: ResolvePanel(row: state.rows[4], identity: identity, run: CompareRunInfo(),
                                      onHolds: { _ in }, onAsk: { _ in }), width: narrow).width <= narrow)
        let wide = CompareLayoutMode.tableMinimumWidth
        #expect(size(of: RowsHost(state: state, context: context, stacked: false), width: wide).width <= wide)
    }

    @Test("Offered no space at all, Compare still fits a window of the minimum size")
    func minimum() {
        let window = WindowState()
        window.select(problem: fixture.problem)
        let size = NSHostingController(rootView: environment(CompareView(problem: fixture.problem, window: window)))
            .sizeThatFits(in: .zero)
        #expect(size.width <= WindowRoot.contentMinWidth)
        #expect(size.height <= WindowRoot.minimumHeight - 52)
    }

    /// With `SANGAKU_PREVIEW_DIR` set, writes PNGs for a visual check (pass `TEST_RUNNER_SANGAKU_PREVIEW_DIR`).
    private func render(_ name: String, width: CGFloat, dark: Bool = false, @ViewBuilder _ view: () -> some View) throws {
        let content = environment(view())
            .frame(width: width)
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "\(name) did not render")
        if let folder = ProcessInfo.processInfo.environment["SANGAKU_PREVIEW_DIR"] {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
        }
    }

    @Test("Smoke renders: the table, stacked and blind rows, the resolve panel, the sheets, the fan-out with its banner")
    func renders() throws {
        let (state, context, identity) = parts()
        let (_, blind, hidden) = parts(hidden: true)
        try render("compare-table", width: 1100) { RowsHost(state: state, context: context, stacked: false) }
        try render("compare-table-dark", width: 1100, dark: true) { RowsHost(state: state, context: context, stacked: false) }
        try render("compare-stacked-blind", width: 360) { RowsHost(state: state, context: blind, stacked: true) }
        let run = CompareRunInfo.read(fixture.alignment, live: [:], identity: identity)
        try render("compare-header", width: 1100) {
            CompareHeader(options: [], chosen: (state.first.id, state.second.id), state: state, identity: identity, run: run,
                          window: WindowState(), onAlign: {}, onStop: {}, onViewContext: { _ in })
        }
        try render("compare-header-blind", width: 600) {
            CompareHeader(options: [], chosen: (state.first.id, state.second.id), state: state, identity: hidden,
                          run: CompareRunInfo.read(fixture.alignment, live: [:], identity: hidden), window: WindowState(),
                          onAlign: {}, onStop: {}, onViewContext: { _ in })
        }
        try render("compare-resolve", width: 600) {
            ResolvePanel(row: state.rows[4], identity: identity, run: run,
                         notice: CompareNotice(row: nil, text: "Sent to Model C. The answer arrives in the thread.", isError: false),
                         onHolds: { _ in }, onAsk: { _ in })
        }
        try render("compare-resolve-blind", width: 600) {
            ResolvePanel(row: state.rows[4], identity: hidden, run: CompareRunInfo(), onHolds: { _ in }, onAsk: { _ in })
        }
        try render("compare-align-sheet", width: 480) {
            AlignSheet(problem: fixture.problem, branch: fixture.mainBranch, pair: state.pair,
                       choice: .slot(fixture.slotC.stableID), identity: identity, rerun: true)
        }
        try render("compare-align-sheet-blind", width: 480) {
            AlignSheet(problem: fixture.problem, branch: fixture.mainBranch, pair: state.pair,
                       choice: .slot(fixture.slotC.stableID), identity: hidden, rerun: true)
        }
        try render("compare-question-sheet", width: 560) {
            QuestionSheet(draft: QuestionDraft(title: "Send this row to Model C",
                                               text: CompareWording.refereeRequest(state.rows[4], identity: identity),
                                               slotID: fixture.slotC.stableID, recipient: "Model C"),
                          problem: fixture.problem, branch: fixture.mainBranch, attemptMessageIDs: []) { _ in }
        }
        let authors = AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
        try render("compare-fan-out", width: 900) {
            FanOutBlock(fanOut: fixture.fanOut, attempts: [fixture.messageA, fixture.messageB], problem: fixture.problem,
                        branch: fixture.mainBranch, live: [:], run: nil, notice: nil, refereeGaveVerdicts: true,
                        busy: false, authors: authors, onViewContext: { _ in })
        }
        let empty = fixture.state.problems.createProblem(title: "Empty")
        try render("compare-empty", width: 600) { CompareView(problem: empty, window: WindowState()).frame(height: 360) }
    }
}
