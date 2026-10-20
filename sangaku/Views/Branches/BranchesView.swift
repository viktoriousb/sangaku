import AppKit
import SwiftData
import SwiftUI

/// The Branches screen (⌘4): the problem's approaches as a tree, the selected node's panel, and what every new
/// prompt carries. Selecting a node fills the panel only; Open Messages shows a branch in Thread, Review and Compare.
struct BranchesView: View {
    let problem: Problem
    let window: WindowState

    var body: some View {
        BranchesReader(problem: problem, window: window)
    }
}

/// The tree drawn with frames and rails, or as an indented outline.
enum BranchDisplay: Hashable {
    case tree, outline
}

/// Reads the store once per render: the tree, the offers for the selected branch, and what every prompt carries.
private struct BranchesReader: View {
    let problem: Problem
    let window: WindowState

    @Query private var people: [Person]
    @Environment(\.threadManager) private var threads
    @Environment(\.statementGraph) private var graph
    @Environment(\.problemManager) private var problems

    var body: some View {
        let personIDs = Set(people.map(\.stableID))
        let authors = AuthorDirectory(problem: problem, people: people, catalog: threads?.catalog ?? .standard)
        let streaming = threads?.streamingBranchIDs ?? []
        let live = threads?.liveMessageIDs ?? []
        let graphState = graph?.state(for: problem, people: personIDs) ?? .empty
        let tree = BranchTree.read(problem: problem, graph: graphState, people: personIDs, authors: authors,
                                   running: streaming, live: live, showsDeadEnds: window.showsDeadEnds)
        let shown = window.selectedBranch(in: problem)?.stableID
        let selected = tree[window.branchesSelection]?.id ?? tree[shown]?.id ?? tree.nodes.first?.id
        // The selected node's branch: the branch itself, or the branch an attempt was written on.
        let branchID = tree[selected]?.branch?.id ?? tree[selected]?.attempt?.branchID
        let snapshot = ProblemSnapshot.stable(problem: problem,
                                              notation: problems?.notation(for: problem) ?? NotationRegistry(entries: []),
                                              people: people, graph: graphState)
        BranchesScreen(problem: problem, window: window, tree: tree, selected: selected, shown: shown,
                       branchID: branchID, offers: tree[branchID]?.branch?.offers, carries: PromptCarries(snapshot),
                       authors: authors)
    }
}

/// The screen and its keyboard: J and K move between nodes while the tree has the keyboard; the Branches menu does
/// the same from anywhere in the window.
struct BranchesScreen: View {
    let problem: Problem
    let window: WindowState
    let tree: BranchTree
    let selected: UUID?
    /// The branch this window shows in Thread, Review and Compare.
    let shown: UUID?
    /// The selected node's branch, and what can be done with it.
    let branchID: UUID?
    let offers: BranchOffers?
    let carries: PromptCarries
    let authors: AuthorDirectory

    nonisolated static let padding: CGFloat = 20

    @Environment(\.branchActions) private var actions
    @FocusState private var listFocused: Bool
    @State private var width: CGFloat = 0
    @State private var display = BranchDisplay.tree
    @State private var presenter = UUID()

    var body: some View {
        let mode = BranchesLayoutMode.resolve(width: width)
        // A reader, not an identity-based scroll position: the nodes sit in a custom layout, which offers no scroll
        // targets, but each carries its ID.
        ScrollViewReader { proxy in
            ScrollView {
                BranchesContent(problem: problem, window: window, tree: tree, selected: selected, shown: shown,
                                offers: offers, carries: carries, authors: authors, mode: mode, width: width,
                                display: $display, listFocused: $listFocused)
                    .padding(Self.padding)
            }
            .onChange(of: selected) { _, id in
                // Without animation, so Reduce Motion needs nothing more.
                if let id { proxy.scrollTo(id) }
            }
        }
        // The scroll view's width, never its content's: the tree is laid out at a fixed width taken from this, so
        // measuring the content would feed the tree's width back into itself.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width - 2 * Self.padding }, action: { width = $0 })
        .onKeyPress(characters: ListKeys.characters, phases: [.down, .repeat]) { press in
            guard let next = ListKeys.move(ListKeyInput(press), isTyping: TextEditingProbe.typing(listHasFocus: listFocused),
                                           from: selected, in: tree.nodes.map(\.id)) else { return .ignored }
            window.branchesSelection = next
            return .handled
        }
        .focusedSceneValue(\.branchesControl, BranchesControl(
            presenter: presenter, nodes: tree.nodes.map(\.id), current: selected, branchID: branchID, offers: offers
        ) { menu($0) })
    }

    /// The menu's command. What it reads is what `BranchesControl` is compared by, so it is current.
    private func menu(_ command: BranchesMenuCommand) {
        switch command {
        case .next, .previous:
            guard let next = ListNavigation.move(forward: command == .next, from: selected, in: tree.nodes.map(\.id))
            else { return }
            window.branchesSelection = next
            listFocused = true
        case .intent(let intent):
            actions?(intent)
        }
    }
}

/// Everything inside the screen's scroll view, so it can be measured and drawn without one.
struct BranchesContent: View {
    let problem: Problem
    let window: WindowState
    let tree: BranchTree
    let selected: UUID?
    let shown: UUID?
    let offers: BranchOffers?
    let carries: PromptCarries
    let authors: AuthorDirectory
    let mode: BranchesLayoutMode
    let width: CGFloat
    @Binding var display: BranchDisplay
    var listFocused: FocusState<Bool>.Binding

    @Environment(\.branchActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if mode == .sideBySide {
                HStack(alignment: .top, spacing: 16) {
                    nodes(width: width - BranchesLayoutMode.panelWidth - 16)
                    VStack(spacing: 16) {
                        panel
                        PromptCarriesCard(carries: carries)
                    }
                    .frame(maxWidth: BranchesLayoutMode.panelWidth)
                }
            } else {
                nodes(width: width)
                panel
                PromptCarriesCard(carries: carries)
            }
        }
    }

    @ViewBuilder private var header: some View {
        @Bindable var window = window
        VStack(alignment: .leading, spacing: 4) {
            Text(BranchWording.title).font(.title2.weight(.semibold))
            Text(BranchWording.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        FlowLayout(spacing: 12, lineSpacing: 8) {
            Button("New Branch…") { if let shown { actions?(.newBranch(branchID: shown)) } }
                .disabled(actions == nil || shown == nil)
                .help("Fork the branch this window shows from its latest message; to fork elsewhere, use a message's menu")
            Toggle("Show Dead Ends", isOn: $window.showsDeadEnds)
            Picker("Display", selection: $display) {
                Text("Tree").tag(BranchDisplay.tree)
                Text("Outline").tag(BranchDisplay.outline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        Text(BranchWording.keys + (tree.hiddenDeadEnds > 0
                                   ? " · \(Prose.count(tree.hiddenDeadEnds, "dead end")) hidden" : ""))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Around the tree, inside the width it is given.
    static let inset: CGFloat = 4

    private func nodes(width: CGFloat) -> some View {
        let width = width - 2 * Self.inset
        let select: (UUID) -> Void = { id in
            window.branchesSelection = id
            listFocused.wrappedValue = true
        }
        return Group {
            if display == .tree {
                BranchTreeView(tree: tree, placement: BranchTreePlacement(tree: tree, metrics: .init(width: max(width, 220))),
                               selectedID: selected, shownBranchID: shown, onSelect: select)
            } else {
                BranchOutlineView(tree: tree, selectedID: selected, shownBranchID: shown, onSelect: select)
            }
        }
        .padding(Self.inset)
        .overlay {
            // With no node selected, the tree itself shows that it has the keyboard.
            if listFocused.wrappedValue && selected == nil {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .focusable()
        .focused(listFocused)
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branch tree")
        .accessibilityRotor("Branches") { entries(tree.branchIDs) }
        .accessibilityRotor("Dead ends") { entries(tree.deadEndIDs) }
        .accessibilityRotor("Parked branches") { entries(tree.parkedIDs) }
        .accessibilityRotor("Attempts") { entries(tree.attemptIDs) }
    }

    private func entries(_ ids: [UUID]) -> some AccessibilityRotorContent {
        ForEach(ids, id: \.self) { id in
            AccessibilityRotorEntry(Text(tree[id].map(BranchWording.title) ?? "Node"), id: id)
        }
    }

    @ViewBuilder private var panel: some View {
        if let node = tree[selected] {
            BranchPanel(problem: problem, node: node, tree: tree, window: window, authors: authors, offers: offers)
        }
    }
}

#if DEBUG
#Preview("Branches", traits: .fixture, .fixedLayout(width: 1000, height: 1000)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @State var window = WindowState()
    if let problem = problems.first {
        BranchesView(problem: problem, window: window)
            .branchSheets(problem: problem, window: window)
            .onAppear { window.select(problem: problem) }
    }
}

#Preview("Branches, narrow and dark", traits: .fixture, .fixedLayout(width: 420, height: 1000)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @State var window = WindowState()
    if let problem = problems.first {
        BranchesView(problem: problem, window: window)
            .branchSheets(problem: problem, window: window)
            .onAppear { window.select(problem: problem) }
            .preferredColorScheme(.dark)
    }
}
#endif
