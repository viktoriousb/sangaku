import Foundation

/// Why a statement shows a lower status than its own, in words. Shown beside the status and sent to models.
nonisolated struct StatusExplanation: Hashable, Sendable {
    /// "Capped by Lem 3 (checked by a model)".
    var caps: String?
    /// "Depends on a refuted claim: Claim", or "… through Lem 6".
    var refutedDependency: String?
    /// The statement is on a cycle of dependencies, or uses one.
    var cycle: String?

    var lines: [String] { [caps, refutedDependency, cycle].compactMap { $0 } }
}

/// One statement of a problem as plain values: what it says, what it uses and is used by, the steps it came from,
/// and its derived status.
nonisolated struct StatementNode: Hashable, Sendable, Identifiable {
    /// A step the statement was promoted from.
    nonisolated struct Source: Hashable, Sendable {
        var stepID: UUID
        var attemptID: UUID?
        /// Who wrote the attempt the step belongs to.
        var attemptAuthor: Author?
        var attemptCreatedAt: Date?
        var index: Int
        var confidence: Confidence
    }

    var id: UUID
    var kind: StatementKind
    var label: String
    var statementLaTeX: String
    var createdAt: Date
    var author: Author?
    var isPinned = false
    /// What it uses and what uses it, among the problem's statements, in graph order.
    var uses: [UUID] = []
    var usedBy: [UUID] = []
    /// Ordered by attempt, then step.
    var sources: [Source] = []
    /// A Lean result or fidelity review was given for this wording, so the text is fixed.
    var hasLeanCheck = false
    var hasEvidence = false
    var refutationNote: String?
    var derived: DerivedStatus
    var explanation = StatusExplanation()
    /// The labels of what it uses and what uses it, for what VoiceOver says.
    var usesLabels: [String] = []
    var usedByLabels: [String] = []

    var delicateSources: [Source] { sources.filter { $0.confidence == .delicate } }

    /// The status as models are told it: the displayed status and, when it is held down, why.
    var contextNote: String {
        ([derived.displayed.words] + explanation.lines.map(Self.lowercasingFirst)).joined(separator: "; ")
    }

    /// What VoiceOver says for the statement, edges included: the graph's arrows are not read.
    var accessibilityDescription: String {
        var parts = [label + ", " + kind.word.lowercased(), Self.capitalizingFirst(derived.displayed.words)]
            + explanation.lines
        if !usesLabels.isEmpty { parts.append("Uses " + Prose.list(usesLabels)) }
        if !usedByLabels.isEmpty { parts.append("Used by " + Prose.list(usedByLabels)) }
        return parts.joined(separator: ". ") + "."
    }

    /// The steps as "A·3–5, B·2", with `letter` naming the author of each attempt.
    func sourceSummary(letter: (Author?) -> String) -> String {
        var groups: [(author: Author?, attempt: UUID?, indices: [Int])] = []
        for source in sources {
            if let last = groups.indices.last, groups[last].attempt == source.attemptID {
                groups[last].indices.append(source.index)
            } else {
                groups.append((source.attemptAuthor, source.attemptID, [source.index]))
            }
        }
        return groups.map { letter($0.author) + "·" + StatementLabels.rangeText($0.indices) }.joined(separator: ", ")
    }

    static func capitalizingFirst(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
    static func lowercasingFirst(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }
}

/// A problem's statements with their dependencies and derived statuses. Built from the store on every read and
/// never cached, so a new verdict, review or edge is reflected by the next read.
nonisolated struct StatementGraphState: Hashable, Sendable {
    /// One statement as read from the store, before derivation.
    nonisolated struct Record: Hashable, Sendable {
        var id: UUID
        var kind: StatementKind
        var label: String
        var statementLaTeX: String
        var createdAt: Date
        var author: Author?
        var own: StatementStatus
        /// May name statements outside the problem; those count as missing (proposed).
        var uses: [UUID] = []
        var sources: [StatementNode.Source] = []
        var hasLeanCheck = false
        var hasEvidence = false
        var refutationNote: String?
    }

    /// Ordered by creation, then label, then ID, so every read gives the same order.
    let nodes: [StatementNode]
    let pinnedID: UUID?
    let usesGraph: UsesGraph
    private let positions: [UUID: Int]

    static let empty = StatementGraphState(records: [], pinnedID: nil)

    init(records: [Record], pinnedID: UUID?) {
        var seen = Set<UUID>()
        let records = records
            .sorted { Self.precedes(($0.createdAt, $0.label, $0.id), ($1.createdAt, $1.label, $1.id)) }
            .filter { seen.insert($0.id).inserted }
        let positions = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($1.id, $0) })
        // A to-many relationship has no order: edges are taken in graph order, so caps are named the same way
        // on every read.
        let uses = records.map { record in
            Array(Set(record.uses.filter { positions[$0] != nil }))
                .sorted { (positions[$0] ?? 0) < (positions[$1] ?? 0) }
        }
        let derived = StatusDerivation.derive(records.enumerated().map { index, record in
            let missing = Set(record.uses.filter { positions[$0] == nil }).sorted { $0.uuidString < $1.uuidString }
            return StatementFacts(id: record.id, own: record.own, uses: uses[index] + missing)
        })
        var usedBy = [[UUID]](repeating: [], count: records.count)
        for (user, dependencies) in uses.enumerated() {
            for dependency in dependencies {
                if let index = positions[dependency] { usedBy[index].append(records[user].id) }
            }
        }
        let labels = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.label) })

        self.positions = positions
        self.pinnedID = pinnedID
        usesGraph = UsesGraph(uses: Dictionary(uniqueKeysWithValues: zip(records.map(\.id), uses)))
        nodes = records.enumerated().map { index, record in
            let status = derived[record.id] ?? DerivedStatus(own: record.own, displayed: .proposed, isUnresolved: true)
            return StatementNode(
                id: record.id, kind: record.kind, label: record.label, statementLaTeX: record.statementLaTeX,
                createdAt: record.createdAt, author: record.author, isPinned: record.id == pinnedID,
                uses: uses[index], usedBy: usedBy[index], sources: record.sources, hasLeanCheck: record.hasLeanCheck,
                hasEvidence: record.hasEvidence, refutationNote: record.refutationNote, derived: status,
                explanation: Self.explain(status, uses: uses[index], labels: labels, derived: derived),
                usesLabels: uses[index].compactMap { labels[$0] }, usedByLabels: usedBy[index].compactMap { labels[$0] })
        }
    }

    subscript(id: UUID?) -> StatementNode? {
        guard let id, let index = positions[id] else { return nil }
        return nodes[index]
    }

    var pinned: StatementNode? { self[pinnedID] }

    /// What every prompt carries as adopted lemmas: every statement that is not refuted, not the problem's theorem
    /// and not a conjecture.
    var adoptedLemmas: [StatementNode] {
        nodes.filter { $0.derived.own != .refuted && !$0.isPinned && $0.kind != .conjecture }
    }

    var refutedClaims: [StatementNode] { nodes.filter { $0.derived.own == .refuted } }

    /// What `user` could newly use without closing a cycle.
    func candidates(toUse user: UUID) -> [StatementNode] {
        usesGraph.candidates(for: user, among: nodes.map(\.id)).compactMap { self[$0] }
    }

    func label(of id: UUID) -> String { self[id]?.label ?? "a missing statement" }

    /// What deleting a statement does, said before it is done: what used it may show a higher status, a refuted
    /// claim leaves every model's context, and its Lean result and evidence go with it.
    func deletionNote(for id: UUID) -> String {
        guard let node = self[id] else { return "" }
        var sentences: [String] = []
        if node.usedByLabels.isEmpty {
            sentences.append("Nothing uses it.")
        } else {
            let one = node.usedByLabels.count == 1
            sentences.append("\(Prose.list(node.usedByLabels)) \(one ? "uses" : "use") it and will no longer, so \(one ? "its" : "their") status may rise.")
        }
        if node.derived.own == .refuted {
            sentences.append("Models will no longer be told it was refuted.")
        }
        if node.hasLeanCheck || node.hasEvidence {
            sentences.append("Its Lean result, fidelity reviews and evidence are deleted with it.")
        }
        if !node.sources.isEmpty {
            sentences.append("The steps it came from stay in the thread.")
        }
        return sentences.joined(separator: " ")
    }

    /// The order statements are read in, and sent to models in: creation time, then label, then ID.
    static func precedes(_ lhs: (Date, String, UUID), _ rhs: (Date, String, UUID)) -> Bool {
        if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        return lhs.2.uuidString < rhs.2.uuidString
    }

    private static func explain(_ status: DerivedStatus, uses: [UUID], labels: [UUID: String],
                                derived: [UUID: DerivedStatus]) -> StatusExplanation {
        var explanation = StatusExplanation()
        if !status.caps.isEmpty {
            explanation.caps = "Capped by " + Prose.list(status.caps.map { cap in
                if cap.dependencyIsMissing { return "a statement no longer in this problem" }
                let name = labels[cap.dependency] ?? "a missing statement"
                return "\(name) (\(cap.dependencyIsRefuted ? StatementStatus.refuted.words : cap.allows.words))"
            })
        }
        if status.dependsOnRefuted {
            let direct = uses.filter { derived[$0]?.own == .refuted }.compactMap { labels[$0] }
            let through = uses.filter { derived[$0]?.own != .refuted && derived[$0]?.dependsOnRefuted == true }
                .compactMap { labels[$0] }
            explanation.refutedDependency = !direct.isEmpty ? "Depends on a refuted claim: " + Prose.list(direct)
                : !through.isEmpty ? "Depends on a refuted claim through " + Prose.list(through)
                : "Depends on a refuted claim"
        }
        if status.isUnresolved {
            explanation.cycle = status.own == .refuted
                ? "Its dependencies form a cycle"
                : "Its dependencies form a cycle, so it counts as proposed"
        }
        return explanation
    }
}

extension Statement {
    /// A Lean result or fidelity review was given for this wording, so the text is fixed (invariant 12).
    var hasLeanCheck: Bool { leanResult != nil || !(fidelityReviews ?? []).isEmpty }
}

extension StatementGraphState {
    /// Reads a problem's statements. `people` holds the stable IDs of `Person` records: only they can check,
    /// accept a refutation or confirm fidelity (invariant 1).
    static func read(problem: Problem, people: Set<UUID>) -> StatementGraphState {
        let records = (problem.statements ?? []).map { statement in
            let sources = (statement.sourceSteps ?? [])
                .map { step in
                    StatementNode.Source(stepID: step.stableID, attemptID: step.attempt?.stableID,
                                         attemptAuthor: step.attempt?.message?.author,
                                         attemptCreatedAt: step.attempt?.message?.createdAt,
                                         index: step.index, confidence: step.confidence)
                }
                .sorted {
                    ($0.attemptCreatedAt ?? .distantPast, $0.attemptID?.uuidString ?? "", $0.index)
                        < ($1.attemptCreatedAt ?? .distantPast, $1.attemptID?.uuidString ?? "", $1.index)
                }
            return Record(id: statement.stableID, kind: statement.kind, label: statement.label,
                          statementLaTeX: statement.statementLaTeX, createdAt: statement.createdAt,
                          author: statement.author,
                          own: StatusRules.ownStatus(StatusInputs.make(for: statement, people: people)),
                          uses: (statement.uses ?? []).map(\.stableID), sources: sources,
                          hasLeanCheck: statement.hasLeanCheck, hasEvidence: !(statement.evidence ?? []).isEmpty,
                          refutationNote: statement.refutationNote)
        }
        return StatementGraphState(records: records, pinnedID: problem.pinnedStatementID)
    }
}
