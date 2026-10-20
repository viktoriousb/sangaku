import SwiftUI

/// The statements as a layered graph: boxes placed by `GraphPlacement`, edges drawn beneath them with an arrowhead
/// at the user's end ("is used by"). VoiceOver skips the edges: each box says what it uses and what uses it, and the
/// detail below lists both as buttons.
struct StatementGraphView: View {
    let state: StatementGraphState
    let placement: GraphPlacement
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onEdit: (UUID) -> Void
    let onDelete: (UUID) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        PlacedLayout(size: placement.size) {
            ForEach(placement.slots, id: \.id) { slot in
                if let node = state[slot.id] {
                    GraphNodeView(node: node, isSelected: node.id == selectedID,
                                  onSelect: { onSelect(node.id) }, onEdit: { onEdit(node.id) },
                                  onDelete: { onDelete(node.id) })
                        .layoutValue(key: SlotRect.self, value: slot.rect)
                }
            }
        }
        .background(alignment: .topLeading) {
            PlacedEdges(strokes: Self.strokes(placement.routes, selectedID: selectedID,
                                              refuted: Set(state.refutedClaims.map(\.id)),
                                              width: EdgeStroke.baseWidth(increasedContrast: contrast == .increased)))
                .frame(width: placement.size.width, height: placement.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Statement graph")
    }

    /// Every edge: the selected statement's edges drawn again on top, darker and wider; an edge from a refuted
    /// statement dashed in the refuted colour; an arrowhead at the user's end.
    static func strokes(_ routes: [GraphPlacement.Route], selectedID: UUID?, refuted: Set<UUID>,
                        width: CGFloat) -> [EdgeStroke] {
        EdgeStroke.layered(routes, width: width, touchesSelection: {
            selectedID != nil && ($0.user == selectedID || $0.dependency == selectedID)
        }) { route in
            let fromRefuted = refuted.contains(route.dependency)
            return EdgeStroke(points: route.points, ink: fromRefuted ? .colour(.refuted) : .plain,
                              dash: fromRefuted ? [4, 3] : [], arrowhead: true)
        }
    }
}
