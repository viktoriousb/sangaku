import Foundation

nonisolated extension StatementStatus {
    /// The statuses in order of trust, lowest first. `refuted` is outside the order.
    static let ladder: [StatementStatus] = [.proposed, .sketched, .modelChecked, .humanChecked, .formallyVerified]

    /// The position in `ladder`; nil for `refuted` and `imported`, which no rank describes.
    var trustRank: Int? {
        switch self {
        case .proposed: 0
        case .sketched: 1
        case .modelChecked: 2
        case .humanChecked: 3
        case .formallyVerified: 4
        case .refuted, .imported: nil
        }
    }

    /// The status in words, for sentences and for what models are told.
    var words: String {
        switch self {
        case .proposed: "proposed"
        case .sketched: "sketched"
        case .modelChecked: "checked by a model"
        case .humanChecked: "checked by a person"
        case .formallyVerified: "verified in Lean"
        case .refuted: "refuted"
        case .imported: "imported, not checked here"
        }
    }
}

/// What the cap needs to know about one statement: its own status and what it uses.
nonisolated struct StatementFacts: Hashable, Sendable {
    var id: UUID
    var own: StatementStatus
    var uses: [UUID]
}

/// A statement's status after the cap by its dependencies (invariant 13).
nonisolated struct DerivedStatus: Hashable, Sendable {
    /// A dependency that holds the status down.
    nonisolated struct Cap: Hashable, Sendable {
        var dependency: UUID
        /// The highest status this dependency lets its users show.
        var allows: StatementStatus
        var dependencyIsRefuted = false
        /// The dependency is not among the statements given, so it counts as proposed.
        var dependencyIsMissing = false
    }

    var own: StatementStatus
    var displayed: StatementStatus
    /// The dependencies that set `displayed`, when it is below `own`; otherwise empty.
    var caps: [Cap] = []
    /// A refuted statement can be reached through `uses`, directly or through other statements.
    var dependsOnRefuted = false
    /// The statement is on a cycle of `uses`, or uses one. Its status cannot be derived, so it counts as proposed.
    var isUnresolved = false
    /// Imported results it rests on, directly or through what it uses, in graph order. They do not lower its status;
    /// they are always said.
    var assumes: [UUID] = []

    var isCapped: Bool { own != .refuted && own != .imported && displayed != own }
}

/// The cap: a statement displays the lowest of its own status and the displayed status of everything it uses. A
/// refuted dependency lets only `sketched` through and is always reported. A refuted statement stays refuted. An
/// imported dependency, a result from the literature, does not lower what uses it: it is recorded in `assumes`, and
/// every status that rests on it says so.
nonisolated enum StatusDerivation {
    /// Derives every statement's displayed status. Iterative, so a long chain cannot exhaust the stack; a cycle in
    /// the data (which the graph never creates, but an import might) fails closed instead of looping.
    static func derive(_ facts: [StatementFacts]) -> [UUID: DerivedStatus] {
        var position: [UUID: Int] = [:]
        var nodes: [StatementFacts] = []
        for fact in facts where position[fact.id] == nil {
            position[fact.id] = nodes.count
            nodes.append(fact)
        }
        let count = nodes.count
        var dependencies = [[Int]](repeating: [], count: count)
        var missing = [[UUID]](repeating: [], count: count)
        var users = [[Int]](repeating: [], count: count)
        for (index, node) in nodes.enumerated() {
            var seen = Set<UUID>()
            for id in node.uses where seen.insert(id).inserted {
                if let dependency = position[id] {
                    dependencies[index].append(dependency)
                    users[dependency].append(index)
                } else {
                    missing[index].append(id)
                }
            }
        }

        // Dependencies first: a statement is resolved once everything it uses is.
        var derived = [DerivedStatus?](repeating: nil, count: count)
        var remaining = dependencies.map(\.count)
        var queue = (0..<count).filter { remaining[$0] == 0 }
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let capping = dependencies[index].filter { nodes[$0].own != .imported }
            let caps = capping.map { dependency -> DerivedStatus.Cap in
                let refuted = nodes[dependency].own == .refuted
                // A resolved dependency is never displayed above its own status, and only refuted ones show refuted.
                let allows: StatementStatus = refuted ? .sketched : (derived[dependency]?.displayed ?? .proposed)
                return DerivedStatus.Cap(dependency: nodes[dependency].id, allows: allows, dependencyIsRefuted: refuted)
            } + missing[index].map { DerivedStatus.Cap(dependency: $0, allows: .proposed, dependencyIsMissing: true) }
            var status = resolve(own: nodes[index].own, caps: caps)
            // What it assumes: the imported results it uses, and what those it uses assume, each once.
            var assumed = Set<Int>()
            for dependency in dependencies[index] {
                if nodes[dependency].own == .imported { assumed.insert(dependency) }
                for id in derived[dependency]?.assumes ?? [] { if let at = position[id] { assumed.insert(at) } }
            }
            status.assumes = assumed.sorted().map { nodes[$0].id }
            derived[index] = status
            for user in users[index] {
                remaining[user] -= 1
                if remaining[user] == 0 { queue.append(user) }
            }
        }

        // Whatever was never reached is on a cycle or uses one.
        for index in 0..<count where derived[index] == nil {
            let own = nodes[index].own
            derived[index] = DerivedStatus(own: own, displayed: own.trustRank == nil ? own : .proposed, isUnresolved: true)
        }

        // Everything that reaches a refuted statement, through any number of steps.
        var marked = [Bool](repeating: false, count: count)
        var stack = (0..<count).filter { nodes[$0].own == .refuted }
        while let index = stack.popLast() {
            for user in users[index] where !marked[user] {
                marked[user] = true
                stack.append(user)
            }
        }

        var result: [UUID: DerivedStatus] = [:]
        for index in 0..<count {
            guard var status = derived[index] else { continue }
            status.dependsOnRefuted = marked[index]
            result[nodes[index].id] = status
        }
        return result
    }

    private static func resolve(own: StatementStatus, caps: [DerivedStatus.Cap]) -> DerivedStatus {
        guard let ownRank = own.trustRank else { return DerivedStatus(own: own, displayed: own) }
        let rank = min(ownRank, caps.compactMap(\.allows.trustRank).min() ?? ownRank)
        return DerivedStatus(own: own, displayed: StatementStatus.ladder[rank],
                             caps: rank < ownRank ? caps.filter { $0.allows.trustRank == rank } : [])
    }
}
