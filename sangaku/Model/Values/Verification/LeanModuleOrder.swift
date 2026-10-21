import Foundation

/// The order statements' code sits in a problem's module: what a statement uses comes before it, so its proof can use
/// that theorem, and ties go by when the statements were made. `uses` is acyclic; should a cycle appear anyway, its
/// members follow in time order and Lean reports what it cannot resolve.
nonisolated enum LeanModuleOrder {
    nonisolated struct Node: Hashable, Sendable {
        var id: UUID
        var createdAt: Date
        var uses: [UUID]
    }

    static func order(_ nodes: [Node]) -> [UUID] {
        let included = Set(nodes.map(\.id))
        let byTime = nodes.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var placed: [UUID] = []
        var done: Set<UUID> = []
        while placed.count < byTime.count {
            let ready = byTime.first { node in
                !done.contains(node.id) && node.uses.filter(included.contains).allSatisfy(done.contains)
            } ?? byTime.first { !done.contains($0.id) }
            guard let next = ready else { break }
            placed.append(next.id)
            done.insert(next.id)
        }
        return placed
    }
}

extension LeanResult {
    /// The checked code in its two parts, or nil when the stored text is not a statement part, a line break and a
    /// proof (a result from before the parts were kept).
    var storedSource: LeanSource? {
        guard !leanStatementSource.isEmpty, source.hasPrefix(leanStatementSource + "\n") else { return nil }
        let proof = String(source.dropFirst(leanStatementSource.count + 1))
        let parts = LeanSource(statementPart: leanStatementSource, proofPart: proof)
        return parts.text == source ? parts : nil
    }
}
