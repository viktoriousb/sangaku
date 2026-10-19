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
            GraphEdges(routes: placement.routes, selectedID: selectedID,
                       refuted: Set(state.refutedClaims.map(\.id)))
                .frame(width: placement.size.width, height: placement.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Statement graph")
    }
}

/// Draws every edge. The selected statement's edges are drawn again on top, darker and wider; an edge from a
/// refuted statement is dashed in the refuted colour.
private struct GraphEdges: View {
    let routes: [GraphPlacement.Route]
    let selectedID: UUID?
    let refuted: Set<UUID>

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let width: CGFloat = contrast == .increased ? 1.5 : 1
        Canvas { context, _ in
            let plain = routes.filter { !touchesSelection($0) }
            let selected = routes.filter(touchesSelection)
            for route in plain { draw(route, in: context, width: width, emphasised: false) }
            for route in selected { draw(route, in: context, width: width + 1, emphasised: true) }
        }
        .accessibilityHidden(true)
    }

    private func touchesSelection(_ route: GraphPlacement.Route) -> Bool {
        selectedID != nil && (route.user == selectedID || route.dependency == selectedID)
    }

    private func draw(_ route: GraphPlacement.Route, in context: GraphicsContext, width: CGFloat, emphasised: Bool) {
        guard route.points.count >= 2, let tip = route.points.last else { return }
        let fromRefuted = refuted.contains(route.dependency)
        let color: Color = fromRefuted ? ColorToken.refuted.color : (emphasised ? .primary : .secondary.opacity(0.6))
        var path = Path()
        path.addLines(route.points)
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineJoin: .round, dash: fromRefuted ? [4, 3] : []))
        // An arrowhead at the user, along the last segment.
        let base = route.points[route.points.count - 2]
        let length = max(hypot(tip.x - base.x, tip.y - base.y), 0.001)
        let (dx, dy) = ((tip.x - base.x) / length, (tip.y - base.y) / length)
        let back = CGPoint(x: tip.x - dx * 6, y: tip.y - dy * 6)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: back.x - dy * 3.5, y: back.y + dx * 3.5))
        head.addLine(to: CGPoint(x: back.x + dy * 3.5, y: back.y - dx * 3.5))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

/// Places each subview at the rectangle it carries in `SlotRect`, in a fixed size.
private struct PlacedLayout: Layout {
    let size: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let rect = subview[SlotRect.self]
            subview.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                          proposal: ProposedViewSize(rect.size))
        }
    }
}

nonisolated private struct SlotRect: LayoutValueKey {
    static let defaultValue = CGRect.zero
}
