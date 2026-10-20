import SwiftUI

/// One edge to draw: its path, ink, pattern and width, and whether it ends in an arrowhead. Pure, so what each graph
/// draws is tested without drawing.
nonisolated struct EdgeStroke: Equatable, Sendable {
    nonisolated enum Ink: Equatable, Sendable {
        /// A quiet line behind the boxes.
        case plain
        /// An edge of the selection, drawn darker.
        case emphasised
        case colour(ColorToken)
    }

    var points: [CGPoint]
    var ink: Ink
    var dash: [CGFloat] = []
    var width: CGFloat = 1
    var arrowhead = false
}

nonisolated extension EdgeStroke {
    /// The width of a quiet edge: wider under Increase Contrast.
    static func baseWidth(increasedContrast: Bool) -> CGFloat { increasedContrast ? 1.5 : 1 }

    /// Every edge, the selection's last so they lie on top: those a point wider and, unless coloured, in
    /// `.emphasised` ink. `stroke` gives an edge's path, pattern and colour.
    static func layered<Route>(_ routes: [Route], width: CGFloat, touchesSelection: (Route) -> Bool,
                               stroke: (Route) -> EdgeStroke) -> [EdgeStroke] {
        func styled(_ route: Route, emphasised: Bool) -> EdgeStroke {
            var edge = stroke(route)
            edge.width = emphasised ? width + 1 : width
            if emphasised, edge.ink == .plain { edge.ink = .emphasised }
            return edge
        }
        return routes.filter { !touchesSelection($0) }.map { styled($0, emphasised: false) }
            + routes.filter(touchesSelection).map { styled($0, emphasised: true) }
    }
}

/// Draws edges in the order given, under the boxes of a `PlacedLayout`. VoiceOver skips them: each box says in words
/// how it relates to the others.
struct PlacedEdges: View {
    let strokes: [EdgeStroke]

    var body: some View {
        Canvas { context, _ in
            for stroke in strokes { draw(stroke, in: context) }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ stroke: EdgeStroke, in context: GraphicsContext) {
        guard stroke.points.count >= 2, let tip = stroke.points.last else { return }
        let color: Color = switch stroke.ink {
        case .plain: .secondary.opacity(0.6)
        case .emphasised: .primary
        case .colour(let colour): colour.color
        }
        var path = Path()
        path.addLines(stroke.points)
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: stroke.width, lineJoin: .round, dash: stroke.dash))
        guard stroke.arrowhead else { return }
        // An arrowhead along the last segment.
        let base = stroke.points[stroke.points.count - 2]
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
