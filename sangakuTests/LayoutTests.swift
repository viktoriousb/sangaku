import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import sangaku

/// Layout at the sizes a window can actually have: no column is squeezed below its content, and the composer
/// keeps a fixed height however long the draft gets.
@Suite("Layout", .serialized)
struct LayoutTests {
    private let fixture = PreviewFixtures.make()

    private func environment<V: View>(_ view: V) -> some View {
        view
            .appEnvironment(fixture.state)
            .environment(\.mathContext, fixture.mathContext)
            .modelContainer(fixture.state.container)
    }

    /// The size a view needs when offered `width`. Wider than `width` means the view cannot shrink to it and
    /// would be clipped.
    private func size<V: View>(of view: V, width: CGFloat) -> CGSize {
        NSHostingController(rootView: environment(view))
            .sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    @Test("Offered no space at all, as AppKit does to find a column's minimum, the thread still fits a window of the minimum size")
    func threadMinimumSize() async {
        // With the key missing the composer shows its banner, the tallest state it has.
        await fixture.state.credentials.refresh(ProviderID.anthropic)
        let window = WindowState()
        window.select(problem: fixture.problem)
        let size = NSHostingController(rootView: environment(ThreadView(problem: fixture.problem, window: window)))
            .sizeThatFits(in: .zero)
        #expect(size.width <= WindowRoot.contentMinWidth)
        // The toolbar takes about 52 pt of the window's height.
        #expect(size.height <= WindowRoot.minimumHeight - 52, "the composer would push Send below the window")
    }

    @Test("The window's minimum leaves room for both side columns, counted as macOS 26 counts them")
    func windowMinimum() {
        // The inspector starts shown.
        let size = size(of: WindowRoot(), width: 100)
        #expect(size.width >= WindowRoot.minimumWidth(inspector: true) - 1)
        #expect(size.height >= WindowRoot.minimumHeight - 1)
        #expect(WindowRoot.minimumWidth(inspector: true) - WindowRoot.minimumWidth(inspector: false)
                == WindowRoot.inspectorWidth)
        #expect(WindowRoot.minimumWidth(inspector: false)
                == 2 * (WindowRoot.sidebarWidth + WindowRoot.sidebarMargin) + WindowRoot.contentMinWidth)
    }

    @Test("The sidebar's notation actions and the inspector fit their columns")
    func sideColumnsFit() {
        // A sidebar row is inset on both sides; leave room for that.
        let actions = size(of: NotationActions(add: {}, importPreamble: {}), width: WindowRoot.sidebarWidth - 40)
        #expect(actions.width <= WindowRoot.sidebarWidth - 40)
        // The example's graph with a capped statement selected: its widest state.
        let window = WindowState()
        window.select(problem: fixture.problem)
        window.selectedNodeID = fixture.cappedLemma.stableID
        let inspector = size(of: InspectorContent(window: window), width: WindowRoot.inspectorWidth)
        #expect(inspector.width <= WindowRoot.inspectorWidth)
        #expect(size(of: InspectorContent(window: WindowState()), width: WindowRoot.inspectorWidth).width
                <= WindowRoot.inspectorWidth)
    }

    @Test("Everything in the workspace fits its narrowest width")
    func workspaceFits() {
        // The thread pads its content by 24 on each side.
        let width = WindowRoot.contentMinWidth - 48
        #expect(size(of: PinnedProblemCard(problem: fixture.problem, onEdit: {}), width: width).width <= width)
        #expect(size(of: Composer(problem: fixture.problem, branch: fixture.mainBranch), width: width).width <= width)
        let messages = fixture.mainBranch.sortedMessages
        let items = ThreadItem.make(messages)
        let context = ThreadContext(
            problem: fixture.problem, branch: fixture.mainBranch, items: items, messages: messages, live: [:], runs: [:],
            notices: [:], authors: AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard),
            busy: false)
        #expect(items.contains { if case .fanOut = $0 { true } else { false } }, "the fan-out is one item")
        for item in items {
            let view = ThreadItemView(item: item, context: context, onViewContext: { _ in })
            #expect(size(of: view, width: width).width <= width, "\(item)")
        }
    }

    /// A fan-out to four provers and a referee: the longest send label and estimate the composer shows.
    private func bigPlan() -> SendPlan {
        let problem = fixture.problem
        for _ in 0..<2 {
            fixture.state.problems.addSlot(to: problem, providerID: ProviderID.anthropic, modelID: "claude-opus-5-5")
        }
        let draft = fixture.state.threads.draft(for: fixture.mainBranch.stableID)
        draft.selection = SendSelection(recipients: Set(problem.sortedModelSlots.filter { $0.role == .prover }.map(\.stableID)),
                                        refereeSlotID: fixture.slotC.stableID)
        draft.text = "Prove it."
        return fixture.state.threads.plan(problem: problem, branch: fixture.mainBranch, draft: draft)
    }

    @Test("A fan-out's send bar fits the narrowest composer: Send shortens rather than widen it")
    func sendBarFits() {
        let plan = bigPlan()
        #expect(plan.sendLabel == "Send to A, B, D, E, then C")
        // The composer pads its content by 14 on each side.
        let width = WindowRoot.contentMinWidth - 48 - 28
        let bar = SendBar(plan: plan, streaming: false, stopsAll: false, canSend: true, send: {}, stop: {})
        #expect(size(of: bar, width: width).width <= width)
        #expect(NSHostingController(rootView: environment(bar)).sizeThatFits(in: .zero).width <= width,
                "offered no space, as AppKit does, it still asks for no more than the narrowest column")
    }

    @Test("With a fan-out's estimate shown, the composer fits the narrowest column, leaves room in a minimum window, and keeps its height while typing")
    func composerWithPlanFits() async {
        // With the key missing the composer shows its banner, the tallest state it has.
        await fixture.state.credentials.refresh(ProviderID.anthropic)
        let plan = bigPlan()
        let composer = Composer(problem: fixture.problem, branch: fixture.mainBranch, plan: plan)
        let width = WindowRoot.contentMinWidth - 48
        let narrow = size(of: composer, width: width)
        #expect(narrow.width <= width)
        // The toolbar takes about 52 pt; leave the thread at least 40 pt above the composer.
        #expect(narrow.height <= WindowRoot.minimumHeight - 52 - 40, "\(narrow.height)")
        let draft = fixture.state.threads.draft(for: fixture.mainBranch.stableID)
        let short = size(of: composer, width: 600).height
        draft.text = (1...60).map { "Line \($0): $$q \\mid p + 1.$$" }.joined(separator: "\n")
        #expect(size(of: composer, width: 600).height == short)
    }

    @Test("Attempt cards sit side by side when there is room and stack when there is not")
    func attemptCardsStack() {
        let layout = EqualColumnsLayout()
        #expect(layout.columns(for: WindowRoot.contentMinWidth - 48, count: 2) == 1)
        #expect(layout.columns(for: 600, count: 2) == 2)
        // The thread's content is at most 860 − 2 × 24 = 812 wide: three attempts still fit side by side.
        #expect(layout.columns(for: 812, count: 3) == 3)
        #expect(layout.columns(for: 500, count: 3) == 1)
        #expect(layout.columns(for: 2000, count: 2) == 2, "never more columns than cards")
    }

    @Test("Typing never changes the composer's height, so Send stays in the window")
    func composerHeightIsStable() async {
        await fixture.state.credentials.refresh(ProviderID.anthropic)
        let draft = fixture.state.threads.draft(for: fixture.mainBranch.stableID)
        let composer = Composer(problem: fixture.problem, branch: fixture.mainBranch)
        draft.text = ""
        let empty = size(of: composer, width: 600).height
        draft.text = "One line with $n_p \\equiv 1 \\pmod{p}$."
        let short = size(of: composer, width: 600).height
        draft.text = (1...60).map { "Line \($0): suppose $n_q = p^2$ and $$q \\mid p + 1.$$" }.joined(separator: "\n")
        let long = size(of: composer, width: 600).height
        #expect(empty == short)
        #expect(short == long)
        #expect(long < 400, "the composer stays well inside a window of the minimum height")
    }
}
