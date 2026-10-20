import CoreGraphics
import Foundation

/// Where each node of the Branches tree sits and the rail of every edge. Pure, so it is tested without drawing. The
/// tree is drawn turned on its side: one row per node in reading order, each indented under its parent, so it wraps
/// to any width the workspace offers and reads in the same order as the outline and VoiceOver. A child's rail runs
/// down its parent's left side from the sibling above it and turns into the child, so siblings never draw over each
/// other; a dead end's rail is dashed and a parked branch's dotted, like its frame.
nonisolated struct BranchTreePlacement: Equatable, Sendable {
    nonisolated struct Metrics: Equatable, Sendable {
        var width: CGFloat
        var rowHeight: CGFloat = 52
        var vGap: CGFloat = 10
        var indent: CGFloat = 24
        /// Indentation stops growing before a node would be narrower than this.
        var minNodeWidth: CGFloat = 200
        /// How far into its parent a child's rail runs.
        var rail: CGFloat = 12

        func x(depth: Int) -> CGFloat {
            min(CGFloat(depth) * indent, max(0, width - minNodeWidth))
        }
    }

    nonisolated struct Slot: Equatable, Sendable {
        var id: UUID
        var rect: CGRect
        var depth: Int
    }

    nonisolated struct Route: Equatable, Sendable {
        var parent: UUID
        var child: UUID
        var points: [CGPoint]
        var pattern: BorderPattern
    }

    /// In reading order, which is also the Tab order.
    private(set) var slots: [Slot] = []
    private(set) var routes: [Route] = []
    private(set) var size: CGSize = .zero

    func slot(_ id: UUID) -> Slot? { slots.first { $0.id == id } }

    init(tree: BranchTree, metrics: Metrics) {
        var rects: [UUID: CGRect] = [:]
        for (row, node) in tree.nodes.enumerated() {
            let x = metrics.x(depth: node.depth)
            let rect = CGRect(x: x, y: CGFloat(row) * (metrics.rowHeight + metrics.vGap),
                              width: max(metrics.width - x, 1), height: metrics.rowHeight)
            rects[node.id] = rect
            slots.append(Slot(id: node.id, rect: rect, depth: node.depth))
        }
        var lastChild: [UUID: UUID] = [:]
        for (row, node) in tree.nodes.enumerated() {
            guard let parentID = node.parentID, let parent = rects[parentID], let child = rects[node.id] else { continue }
            let pattern: BorderPattern = switch node.branch?.state {
            case .deadEnd?: .dashed
            case .parked?: .dotted
            default: .solid
            }
            let railX = parent.minX + metrics.rail
            let points: [CGPoint]
            if child.minX > railX + 2 {
                // From the sibling above (its rail ends at its middle), else from the parent's bottom.
                let startY = lastChild[parentID].flatMap { rects[$0]?.midY } ?? parent.maxY
                points = [CGPoint(x: railX, y: startY), CGPoint(x: railX, y: child.midY),
                          CGPoint(x: child.minX, y: child.midY)]
            } else {
                // Indentation is spent: a short drop from the row above into the child's top.
                let above = row > 0 ? rects[tree.nodes[row - 1].id]?.maxY ?? parent.maxY : parent.maxY
                points = [CGPoint(x: child.minX + metrics.rail, y: above), CGPoint(x: child.minX + metrics.rail, y: child.minY)]
            }
            lastChild[parentID] = node.id
            routes.append(Route(parent: parentID, child: node.id, points: points, pattern: pattern))
        }
        size = CGSize(width: metrics.width, height: slots.last.map { $0.rect.maxY } ?? 0)
    }

    /// The rails as strokes: the selection's own rails darker and wider, each in its child's pattern.
    func strokes(selectedID: UUID?, width: CGFloat) -> [EdgeStroke] {
        Self.strokes(routes, selectedID: selectedID, width: width)
    }

    static func strokes(_ routes: [Route], selectedID: UUID?, width: CGFloat) -> [EdgeStroke] {
        EdgeStroke.layered(routes, width: width, touchesSelection: {
            selectedID != nil && ($0.child == selectedID || $0.parent == selectedID)
        }) { route in
            let dash: [CGFloat] = switch route.pattern {
            case .solid: []
            case .dashed: [5, 3]
            case .dotted: [1.5, 3]
            }
            return EdgeStroke(points: route.points, ink: .plain, dash: dash)
        }
    }
}
