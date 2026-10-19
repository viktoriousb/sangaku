import CoreGraphics
import Foundation

/// Where each statement sits in the inspector's graph, and the path of every edge. Pure, so it is tested without
/// drawing. Statements nothing uses (the theorem, usually) are on top and what they use below, so every edge runs
/// upward from a dependency to its user: the arrow means "is used by". Statements with no edges come last.
nonisolated struct GraphPlacement: Equatable, Sendable {
    nonisolated struct Metrics: Equatable, Sendable {
        var width: CGFloat
        var maxColumns = 3
        var hGap: CGFloat = 14
        var vGap: CGFloat = 40
        var nodeHeight: CGFloat = 56
        var minNodeWidth: CGFloat = 72

        var columns: Int { max(1, min(maxColumns, Int((width + hGap) / (minNodeWidth + hGap)))) }
        var nodeWidth: CGFloat {
            max(minNodeWidth, ((width - hGap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
        }
    }

    nonisolated struct Slot: Equatable, Sendable {
        var id: UUID
        var rect: CGRect
        var row: Int
    }

    nonisolated struct Route: Equatable, Sendable {
        var dependency: UUID
        var user: UUID
        /// From the dependency's top edge to the user's bottom edge.
        var points: [CGPoint]
        /// No free lane was found, or the edge touches a cycle: it is drawn straight, behind the statements.
        var crossesNodes = false
    }

    /// In reading order, which is also the Tab order.
    private(set) var slots: [Slot] = []
    private(set) var routes: [Route] = []
    private(set) var size: CGSize = .zero

    func slot(_ id: UUID) -> Slot? { slots.first { $0.id == id } }

    init(state: StatementGraphState, metrics: Metrics) {
        let nodes = state.nodes
        let order = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let unresolved = nodes.filter(\.derived.isUnresolved).map(\.id)
        let isolated = nodes.filter {
            !$0.isPinned && !$0.derived.isUnresolved && $0.uses.isEmpty && $0.usedBy.isEmpty
        }.map(\.id)
        let excluded = Set(unresolved + isolated)
        let layered = nodes.map(\.id).filter { !excluded.contains($0) }
        let layeredSet = Set(layered)
        func uses(_ id: UUID) -> [UUID] { (state[id]?.uses ?? []).filter(layeredSet.contains) }
        func users(_ id: UUID) -> [UUID] { (state[id]?.usedBy ?? []).filter(layeredSet.contains) }

        // Longest path from the top: a statement sits one layer below the lowest statement using it.
        var waiting = Dictionary(uniqueKeysWithValues: layered.map { ($0, users($0).count) })
        var layer: [UUID: Int] = [:]
        var queue = layered.filter { waiting[$0] == 0 }
        for id in queue { layer[id] = 0 }
        var head = 0
        while head < queue.count {
            let id = queue[head]
            head += 1
            for dependency in uses(id) {
                layer[dependency] = max(layer[dependency] ?? 0, (layer[id] ?? 0) + 1)
                waiting[dependency, default: 0] -= 1
                if waiting[dependency] == 0 { queue.append(dependency) }
            }
        }
        var layers = [[UUID]](repeating: [], count: (layer.values.max() ?? -1) + 1)
        for id in layered { if let index = layer[id] { layers[index].append(id) } }
        // Resolved statements always get a layer; anything else is drawn with the cycles.
        let leftover = layered.filter { layer[$0] == nil }

        let width = metrics.nodeWidth, height = metrics.nodeHeight
        var rows: [[UUID]] = []
        var rects: [UUID: CGRect] = [:]
        func place(_ ids: [UUID]) {
            for start in stride(from: 0, to: ids.count, by: metrics.columns) {
                let row = Array(ids[start..<min(start + metrics.columns, ids.count)])
                let rowWidth = CGFloat(row.count) * width + CGFloat(row.count - 1) * metrics.hGap
                let x0 = ((metrics.width - rowWidth) / 2).rounded(.down)
                let y = CGFloat(rows.count) * (height + metrics.vGap)
                for (index, id) in row.enumerated() {
                    rects[id] = CGRect(x: x0 + CGFloat(index) * (width + metrics.hGap), y: y, width: width, height: height)
                }
                rows.append(row)
            }
        }
        for (index, members) in layers.enumerated() {
            if index == 0 {
                place(members.sorted { (state[$0]?.isPinned == true ? 0 : 1, order[$0] ?? 0)
                    < (state[$1]?.isPinned == true ? 0 : 1, order[$1] ?? 0) })
            } else {
                // Under the statements that use them, so edges cross as little as they can.
                func center(_ id: UUID) -> CGFloat {
                    let xs = users(id).compactMap { rects[$0]?.midX }
                    return xs.isEmpty ? .greatestFiniteMagnitude : xs.reduce(0, +) / CGFloat(xs.count)
                }
                place(members.sorted { (center($0), order[$0] ?? 0) < (center($1), order[$1] ?? 0) })
            }
        }
        place(unresolved + leftover)
        place(isolated)

        var row: [UUID: Int] = [:]
        for (index, ids) in rows.enumerated() { for id in ids { row[id] = index } }
        slots = rows.enumerated().flatMap { index, ids in
            ids.compactMap { id in rects[id].map { Slot(id: id, rect: $0, row: index) } }
        }
        size = CGSize(width: metrics.width,
                      height: rows.isEmpty ? 0 : CGFloat(rows.count) * height + CGFloat(rows.count - 1) * metrics.vGap)
        routes = Self.route(state: state, layered: layered, uses: uses, rects: rects, row: row, rows: rows,
                            order: order, metrics: metrics)
    }

    // MARK: Edges

    private static func route(state: StatementGraphState, layered: [UUID], uses: (UUID) -> [UUID],
                              rects: [UUID: CGRect], row: [UUID: Int], rows: [[UUID]], order: [UUID: Int],
                              metrics: Metrics) -> [Route] {
        struct Edge {
            var dependency: UUID
            var user: UUID
            var from: CGRect
            var to: CGRect
            var exitX: CGFloat = 0
            var entryX: CGFloat = 0
            var laneX: CGFloat?
            var exitY: CGFloat = 0
            var entryY: CGFloat = 0
            var crossesNodes = false
        }
        var edges: [Edge] = []
        for user in layered {
            for dependency in uses(user) {
                guard let from = rects[dependency], let to = rects[user],
                      let low = row[dependency], let high = row[user], low > high else { continue }
                edges.append(Edge(dependency: dependency, user: user, from: from, to: to))
            }
        }

        // Ports: each edge leaves its dependency's top edge and enters its user's bottom edge at its own x,
        // ordered by where the other end is, so edges leaving one statement do not cross each other.
        func spread(_ indices: [Int], along rect: CGRect, other: (Int) -> (CGFloat, Int)) -> [Int: CGFloat] {
            let sorted = indices.sorted { other($0) < other($1) }
            var xs: [Int: CGFloat] = [:]
            for (position, index) in sorted.enumerated() {
                xs[index] = rect.minX + rect.width * CGFloat(position + 1) / CGFloat(sorted.count + 1)
            }
            return xs
        }
        let byDependency = Dictionary(grouping: edges.indices) { edges[$0].dependency }
        for (id, indices) in byDependency {
            guard let rect = rects[id] else { continue }
            for (index, x) in spread(indices, along: rect, other: { (edges[$0].to.midX, order[edges[$0].user] ?? 0) }) {
                edges[index].exitX = x
            }
        }
        let byUser = Dictionary(grouping: edges.indices) { edges[$0].user }
        for (id, indices) in byUser {
            guard let rect = rects[id] else { continue }
            for (index, x) in spread(indices, along: rect, other: { (edges[$0].from.midX, order[edges[$0].dependency] ?? 0) }) {
                edges[index].entryX = x
            }
        }

        // Lanes: an edge spanning more than one gap runs up through a free space between the statements of the
        // rows it passes.
        var laneUse: [String: Int] = [:]
        for index in edges.indices {
            guard let low = row[edges[index].dependency], let high = row[edges[index].user], low - high > 1 else { continue }
            let between: [UUID] = ((high + 1)..<low).flatMap { rows[$0] }
            let blocked: [(CGFloat, CGFloat)] = between.compactMap { id -> (CGFloat, CGFloat)? in
                guard let rect = rects[id] else { return nil }
                return (rect.minX - 3, rect.maxX + 3)
            }.sorted { $0.0 < $1.0 }
            var free: [(CGFloat, CGFloat)] = []
            var cursor: CGFloat = 0
            for (start, end) in blocked {
                if start > cursor { free.append((cursor, start)) }
                cursor = max(cursor, end)
            }
            if cursor < metrics.width { free.append((cursor, metrics.width)) }
            free = free.filter { $0.1 - $0.0 >= 2 }
            let target = (edges[index].exitX + edges[index].entryX) / 2
            func distance(_ interval: (CGFloat, CGFloat)) -> CGFloat {
                target < interval.0 ? interval.0 - target : target > interval.1 ? target - interval.1 : 0
            }
            guard let lane = free.min(by: { distance($0) < distance($1) }) else {
                edges[index].crossesNodes = true
                continue
            }
            let key = "\(high)-\(low)-\(lane.0)"
            let taken = laneUse[key, default: 0]
            laneUse[key] = taken + 1
            let center = (lane.0 + lane.1) / 2
            let offset = CGFloat((taken + 1) / 2) * 3 * (taken.isMultiple(of: 2) ? 1 : -1)
            edges[index].laneX = min(max(center + offset, lane.0 + 1), lane.1 - 1)
        }

        // Gaps: every horizontal run gets its own height in the gap it crosses, so runs never overlap.
        struct Run { var edge: Int; var exit: Bool; var midX: CGFloat }
        var gaps: [Int: [Run]] = [:]
        for (index, edge) in edges.enumerated() {
            guard let low = row[edge.dependency], let high = row[edge.user] else { continue }
            if let lane = edge.laneX {
                gaps[low, default: []].append(Run(edge: index, exit: true, midX: (edge.exitX + lane) / 2))
                gaps[high + 1, default: []].append(Run(edge: index, exit: false, midX: (lane + edge.entryX) / 2))
            } else {
                gaps[low, default: []].append(Run(edge: index, exit: true, midX: (edge.exitX + edge.entryX) / 2))
            }
        }
        let rowPitch = metrics.nodeHeight + metrics.vGap
        for (gap, runs) in gaps {
            let top = CGFloat(gap) * rowPitch - metrics.vGap
            let sorted = runs.sorted { ($0.midX, $0.edge) < ($1.midX, $1.edge) }
            for (position, run) in sorted.enumerated() {
                let y = top + metrics.vGap * CGFloat(position + 1) / CGFloat(sorted.count + 1)
                if run.exit { edges[run.edge].exitY = y } else { edges[run.edge].entryY = y }
                if edges[run.edge].laneX == nil { edges[run.edge].entryY = y }
            }
        }

        var routes = edges.map { edge -> Route in
            let start = CGPoint(x: edge.exitX, y: edge.from.minY)
            let end = CGPoint(x: edge.entryX, y: edge.to.maxY)
            if edge.crossesNodes {
                return Route(dependency: edge.dependency, user: edge.user, points: [start, end], crossesNodes: true)
            }
            if let lane = edge.laneX {
                return Route(dependency: edge.dependency, user: edge.user, points: [
                    start, CGPoint(x: edge.exitX, y: edge.exitY), CGPoint(x: lane, y: edge.exitY),
                    CGPoint(x: lane, y: edge.entryY), CGPoint(x: edge.entryX, y: edge.entryY), end,
                ])
            }
            return Route(dependency: edge.dependency, user: edge.user, points: [
                start, CGPoint(x: edge.exitX, y: edge.exitY), CGPoint(x: edge.entryX, y: edge.exitY), end,
            ])
        }

        // Edges of statements on a cycle: straight, centre to centre, behind everything.
        for node in state.nodes where node.derived.isUnresolved {
            for dependency in node.uses {
                guard let from = rects[dependency], let to = rects[node.id] else { continue }
                routes.append(Route(dependency: dependency, user: node.id,
                                    points: [CGPoint(x: from.midX, y: from.midY), CGPoint(x: to.midX, y: to.midY)],
                                    crossesNodes: true))
            }
        }
        return routes.sorted { (order[$0.user] ?? 0, order[$0.dependency] ?? 0) < (order[$1.user] ?? 0, order[$1.dependency] ?? 0) }
    }
}
