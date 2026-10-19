import CoreGraphics
import Foundation
import Testing
@testable import sangaku

@Suite("Graph placement")
struct GraphPlacementTests {
    private let fixture = PreviewFixtures.make()
    private let metrics = GraphPlacement.Metrics(width: InspectorContent.contentWidth)

    private var state: StatementGraphState { fixture.state.graph.state(for: fixture.problem) }

    private func rows(_ placement: GraphPlacement, _ state: StatementGraphState) -> [[String]] {
        Dictionary(grouping: placement.slots, by: \.row).sorted { $0.key < $1.key }
            .map { $0.value.map { state.label(of: $0.id) } }
    }

    private func record(_ id: UUID, _ label: String, uses: [UUID] = [], at offset: Double = 0) -> StatementGraphState.Record {
        StatementGraphState.Record(id: id, kind: .lemma, label: label, statementLaTeX: "$x$",
                                   createdAt: Date(timeIntervalSinceReferenceDate: offset), author: nil,
                                   own: .sketched, uses: uses)
    }

    /// Checks every route: it starts on its dependency's top edge, ends on its user's bottom edge, runs only
    /// horizontally and vertically, passes through no other statement, and shares no horizontal run with another.
    private func checkRoutes(_ placement: GraphPlacement) throws {
        var runs: [(y: CGFloat, from: CGFloat, to: CGFloat, route: Int)] = []
        for (index, route) in placement.routes.enumerated() {
            let from = try #require(placement.slot(route.dependency)).rect
            let to = try #require(placement.slot(route.user)).rect
            let start = try #require(route.points.first), end = try #require(route.points.last)
            #expect(!route.crossesNodes)
            #expect(start.y == from.minY && (from.minX...from.maxX).contains(start.x))
            #expect(end.y == to.maxY && (to.minX...to.maxX).contains(end.x))
            for (a, b) in zip(route.points, route.points.dropFirst()) {
                #expect(a.x == b.x || a.y == b.y, "segments are horizontal or vertical")
                let segment = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                for slot in placement.slots where slot.id != route.user && slot.id != route.dependency {
                    #expect(!slot.rect.insetBy(dx: 0.5, dy: 0.5).intersects(segment.insetBy(dx: -0.01, dy: -0.01)),
                            "a route passes through \(slot.id)")
                }
                if a.y == b.y, a.x != b.x { runs.append((a.y, min(a.x, b.x), max(a.x, b.x), index)) }
            }
        }
        for (i, first) in runs.enumerated() {
            for second in runs[(i + 1)...] where first.route != second.route && abs(first.y - second.y) < 0.5 {
                #expect(min(first.to, second.to) - max(first.from, second.from) <= 0.5, "two horizontal runs overlap")
            }
        }
    }

    @Test("Three statements to a row at the inspector's width")
    func columns() {
        #expect(metrics.columns == 3)
        #expect(metrics.nodeWidth * 3 + metrics.hGap * 2 <= metrics.width)
        #expect(GraphPlacement.Metrics(width: 150).columns == 1)
    }

    @Test("The example: what is used sits below what uses it; the unconnected conjecture comes last")
    func fixtureRows() throws {
        let state = state
        let placement = GraphPlacement(state: state, metrics: metrics)
        #expect(rows(placement, state) == [["Thm 1", "Lem 5", "Lem 7"], ["Lem 3", "Lem 4", "Lem 6"],
                                           ["Lem 1", "Lem 2", "Claim"], ["Conj"]])
        #expect(placement.routes.count == 10)
        #expect(placement.size.width == metrics.width)
        for (index, slot) in placement.slots.enumerated() {
            #expect(slot.rect.minX >= 0 && slot.rect.maxX <= metrics.width)
            for other in placement.slots[(index + 1)...] { #expect(!slot.rect.intersects(other.rect)) }
        }
        try checkRoutes(placement)
        #expect(placement == GraphPlacement(state: state, metrics: metrics), "the same graph is placed the same way")
    }

    @Test("A wide layer wraps onto more rows, and edges from below find a way between the boxes")
    func wrapping() throws {
        let lemmas = (1...5).map { _ in UUID() }
        let theorem = UUID()
        let state = StatementGraphState(records: [record(theorem, "Thm 1", uses: lemmas)]
            + lemmas.enumerated().map { record($1, "Lem \($0 + 1)", at: Double($0 + 1)) }, pinnedID: theorem)
        let placement = GraphPlacement(state: state, metrics: metrics)
        #expect(rows(placement, state) == [["Thm 1"], ["Lem 1", "Lem 2", "Lem 3"], ["Lem 4", "Lem 5"]])
        try checkRoutes(placement)
    }

    @Test("Cycles in the data still place every statement, their edges drawn straight behind")
    func cycles() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let state = StatementGraphState(records: [record(a, "Lem 1", uses: [b]), record(b, "Lem 2", uses: [a], at: 1),
                                                  record(c, "Thm 1", at: 2)], pinnedID: c)
        let placement = GraphPlacement(state: state, metrics: metrics)
        #expect(placement.slots.count == 3)
        #expect(rows(placement, state) == [["Thm 1"], ["Lem 1", "Lem 2"]])
        #expect(placement.routes.count == 2)
        #expect(placement.routes.allSatisfy { $0.crossesNodes })
    }
}

@Suite("Graph nodes (invariant 3)")
struct GraphNodeTests {
    private let fixture = PreviewFixtures.make()

    @Test("Invariant 3: a box shows its displayed status and marks a cap or a refuted dependency in words")
    func marks() throws {
        let state = fixture.state.graph.state(for: fixture.problem)
        let capped = try #require(state[fixture.cappedLemma.stableID])
        let onRefuted = try #require(state[fixture.onRefutedClaim.stableID])
        let plain = try #require(state[fixture.lemmas[0].stableID])
        #expect(GraphNodeView.marker(for: capped)?.text == "↓ Capped")
        #expect(GraphNodeView.marker(for: onRefuted)?.text == "✗ Uses refuted")
        #expect(GraphNodeView.marker(for: onRefuted)?.mark == .refutedDependency)
        #expect(GraphNodeView.marker(for: plain)?.text == nil)
        #expect(StatusStyle.style(for: capped.derived.displayed).glyph != StatusStyle.style(for: capped.derived.own).glyph,
                "a capped statement never looks like its own status")
        let shortLabels = StatementStatus.allCases.map { StatusStyle.style(for: $0).shortLabel }
        #expect(Set(shortLabels).count == shortLabels.count)
        #expect(shortLabels.allSatisfy { !$0.isEmpty })
    }

    @Test("Invariant 13: a refuted dependency stays visible on a box that is also on a cycle")
    func cycleAndRefuted() throws {
        let (a, b, refuted) = (UUID(), UUID(), UUID())
        let state = StatementGraphState(records: [
            .init(id: a, kind: .lemma, label: "Lem 1", statementLaTeX: "", createdAt: .distantPast, own: .sketched, uses: [b, refuted]),
            .init(id: b, kind: .lemma, label: "Lem 2", statementLaTeX: "", createdAt: .distantPast, own: .sketched, uses: [a]),
            .init(id: refuted, kind: .claim, label: "Claim", statementLaTeX: "", createdAt: .distantPast, own: .refuted),
        ], pinnedID: nil)
        let node = try #require(state[a])
        #expect(GraphNodeView.marker(for: node)?.text == "✗ Uses refuted ↻")
        #expect(GraphNodeView.marker(for: node)?.mark == .refutedDependency)
        #expect(node.explanation.cycle == "Its dependencies form a cycle, so it counts as proposed")
    }

    @Test("Invariant 3: a status's words and its label are the same words")
    func words() {
        for status in StatementStatus.allCases {
            #expect(StatusStyle.style(for: status).label == StatementNode.capitalizingFirst(status.words))
        }
    }
}
