import SwiftData
import SwiftUI

/// The Branches tree: nodes placed by `BranchTreePlacement`, rails drawn beneath them. VoiceOver skips the rails;
/// each node says what it is and how it hangs off its parent.
struct BranchTreeView: View {
    let tree: BranchTree
    let placement: BranchTreePlacement
    let selectedID: UUID?
    let shownBranchID: UUID?
    let onSelect: (UUID) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        PlacedLayout(size: placement.size) {
            ForEach(placement.slots, id: \.id) { slot in
                if let node = tree[slot.id] {
                    BranchNodeView(node: node, isSelected: node.id == selectedID, isShown: node.id == shownBranchID,
                                   compact: false) { onSelect(node.id) }
                        .layoutValue(key: SlotRect.self, value: slot.rect)
                        .id(node.id)
                }
            }
        }
        .background(alignment: .topLeading) {
            PlacedEdges(strokes: placement.strokes(selectedID: selectedID,
                                                   width: EdgeStroke.baseWidth(increasedContrast: contrast == .increased)))
                .frame(width: placement.size.width, height: placement.size.height)
        }
        // Laid out at a width the screen measured, but never asking for it: AppKit sizes the window's column from
        // the content's minimum, and a tree that insisted on its width would hold the column at it.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The same tree as an indented list: no frames or rails, for narrow widths and for reading.
struct BranchOutlineView: View {
    let tree: BranchTree
    let selectedID: UUID?
    let shownBranchID: UUID?
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tree.nodes) { node in
                BranchNodeView(node: node, isSelected: node.id == selectedID, isShown: node.id == shownBranchID,
                               compact: true) { onSelect(node.id) }
                    .padding(.leading, CGFloat(min(node.depth, 8)) * 16)
                    .id(node.id)
            }
        }
    }
}

/// One node: its glyph, title and caption, framed in its status's border pattern (invariant 3) unless compact. A
/// branch's menu offers what can be done to it now.
struct BranchNodeView: View {
    let node: BranchTree.Node
    let isSelected: Bool
    /// The branch this window shows in Thread, Review and Compare.
    let isShown: Bool
    let compact: Bool
    let onSelect: () -> Void

    @Environment(\.branchActions) private var actions
    @Environment(\.mathContext) private var math
    @Environment(\.mathRenderer) private var renderer

    var body: some View {
        let style = BranchWording.style(node)
        let title = BranchWording.title(node)
        // VoiceOver hears the title as `MathText` speaks it, never its LaTeX source.
        let sentence = BranchWording.sentence(node, spokenTitle: MathTextComposer.spoken(title, renderer: renderer,
                                                                                        context: math))
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: style.glyph)
                    .foregroundStyle(style.glyphToken.color)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    MathText(title, showsProblems: false)
                        .environment(\.mathContext, smaller)
                        .fontWeight(.semibold)
                        .foregroundStyle(style.ink.color)
                        .lineLimit(1)
                    Text(BranchWording.caption(node))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if node.branch?.isRunning == true {
                    StatusBadge(style: .running, compact: true)
                }
                if isShown {
                    Text("shown")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Thread, Review and Compare show this branch")
                }
            }
            .padding(.horizontal, compact ? 4 : 10)
            .padding(.vertical, compact ? 3 : 0)
            .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .leading)
            .contentShape(.rect)
            .modifier(NodeFrame(style: style, compact: compact, isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .help(sentence)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentence)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var smaller: MathContext {
        var context = math
        context.fontSize = 13
        return context
    }

    @ViewBuilder private var menu: some View {
        if let actions {
            switch node.kind {
            case .branch(let branch):
                Button("Open Messages") { actions(.openMessages(branchID: branch.id)) }
                if let offers = branch.offers {
                    BranchActionItems(branchID: branch.id, offers: offers) { actions($0) }
                }
            case .attempt(let attempt):
                if !attempt.isAdopted {
                    Button(BranchWording.adoptTitle(attempt.author)) { actions(.adopt(attemptID: attempt.id)) }
                }
                Button("Open Messages") { actions(.openMessages(branchID: attempt.branchID)) }
            case .lemma(let lemma):
                Button("Show in Proof Structure") { actions(.revealStatement(lemma.id)) }
                Button("Copy LaTeX Source") { Pasteboard.copy(lemma.statementLaTeX) }
            case .problem:
                Button("Edit Problem…") { actions(.editProblem) }
            }
        }
    }
}

/// A node's frame and its selection ring, a second shape and not only a colour.
private struct NodeFrame: ViewModifier {
    let style: StatusStyle
    let compact: Bool
    let isSelected: Bool

    func body(content: Content) -> some View {
        if compact {
            content
                .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 5))
                .overlay {
                    if isSelected { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5) }
                }
        } else {
            content
                .statusFrame(style, cornerRadius: 8)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11).inset(by: -3).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
    }
}

#if DEBUG
/// The fixture's tree, drawn or as an outline, at a given width.
private struct BranchTreePreview: View {
    let display: BranchDisplay
    let width: CGFloat

    @Query private var problems: [Problem]
    @Query private var people: [Person]
    @Environment(\.statementGraph) private var graph
    @State private var selected: UUID?

    var body: some View {
        if let problem = problems.first {
            let personIDs = Set(people.map(\.stableID))
            let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
            let tree = BranchTree.read(problem: problem, graph: graph?.state(for: problem, people: personIDs) ?? .empty,
                                       people: personIDs, authors: authors, running: [], live: [], showsDeadEnds: true)
            Group {
                if display == .tree {
                    BranchTreeView(tree: tree, placement: BranchTreePlacement(tree: tree, metrics: .init(width: width)),
                                   selectedID: selected ?? tree.deadEndIDs.first, shownBranchID: problem.mainBranchID,
                                   onSelect: { selected = $0 })
                } else {
                    BranchOutlineView(tree: tree, selectedID: selected ?? tree.attemptIDs.first,
                                      shownBranchID: problem.mainBranchID, onSelect: { selected = $0 })
                }
            }
            .frame(width: width)
            .padding()
        }
    }
}

#Preview("Tree", traits: .salvagedFixture, .sizeThatFitsLayout) {
    BranchTreePreview(display: .tree, width: 620)
}

#Preview("Outline, dark", traits: .salvagedFixture, .sizeThatFitsLayout) {
    BranchTreePreview(display: .outline, width: 360)
        .preferredColorScheme(.dark)
}
#endif
