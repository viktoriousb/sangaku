import Foundation

/// The problem's approaches as a tree, derived on every read: the problem, its branches, each branch's attempts, the
/// lemmas salvaged from an attempt, and the branches forked from it. Pre-order, so reading order, Tab order and the
/// outline's order are one. Pure: built from plain facts, tested without the store.
nonisolated struct BranchTree: Equatable, Sendable {
    nonisolated struct BranchFacts: Equatable, Sendable {
        var id: UUID
        var createdAt: Date
        var name: String
        var state: BranchState
        var isMain: Bool
        var isRunning: Bool
        /// The branch owning the message it was forked from, and the attempt that message holds, if any.
        var forkOwnerID: UUID?
        var forkAttemptID: UUID?
        var ownMessages: Int = 0
        var inheritedMessages: Int = 0
        /// Who wrote its own messages, in order of appearance.
        var authors: [String] = []
        var firstMessageAt: Date?
        var lastMessageAt: Date?
        var inContext = false
        /// What can be done to it now; nil in trees built without the store.
        var offers: BranchOffers?
    }

    nonisolated struct AttemptFacts: Equatable, Sendable {
        var id: UUID
        var branchID: UUID
        var createdAt: Date
        var author: String
        var steps: Int
        var isPartial: Bool
        /// What a statement resting on exactly these steps would earn (rules 3 to 5), never more.
        var status: StatementStatus
        var verdict: RefereeOutcome?
        var gapSteps: [Int] = []
        var isAdopted: Bool
        var progress: ReviewProgress
        /// What adopting it would warn about: whether the verdict still covers the steps' text, and whether it stopped.
        var warnings: [AdoptionWarning] = []
    }

    nonisolated struct LemmaFacts: Equatable, Sendable {
        var id: UUID
        var createdAt: Date
        var label: String
        var statementLaTeX: String
        /// The displayed status, after the cap.
        var status: StatementStatus
        /// The attempt its source steps belong to.
        var attemptID: UUID
    }

    nonisolated enum Kind: Equatable, Sendable {
        /// The problem, its theorem's displayed status, and whether the adopted proof stopped before it finished.
        case problem(title: String, theorem: String?, status: StatementStatus?, partialProof: Bool)
        case branch(BranchFacts)
        case attempt(AttemptFacts)
        case lemma(LemmaFacts)
    }

    /// How a node hangs off its parent.
    nonisolated enum Link: Equatable, Sendable {
        case approach, attempt, fork, salvaged
    }

    nonisolated struct Node: Equatable, Sendable, Identifiable {
        var id: UUID
        var depth: Int
        var parentID: UUID?
        var kind: Kind
        var link: Link?

        var branch: BranchFacts? { if case .branch(let facts) = kind { facts } else { nil } }
        var attempt: AttemptFacts? { if case .attempt(let facts) = kind { facts } else { nil } }
        var lemma: LemmaFacts? { if case .lemma(let facts) = kind { facts } else { nil } }
    }

    var nodes: [Node]
    /// Dead ends left out because "Show dead ends" is off.
    var hiddenDeadEnds: Int

    subscript(id: UUID?) -> Node? { nodes.first { $0.id == id } }

    /// Rotor lists.
    var branchIDs: [UUID] { nodes.filter { $0.branch != nil }.map(\.id) }
    var deadEndIDs: [UUID] { nodes.filter { $0.branch?.state == .deadEnd }.map(\.id) }
    var parkedIDs: [UUID] { nodes.filter { $0.branch?.state == .parked }.map(\.id) }
    var attemptIDs: [UUID] { nodes.filter { $0.attempt != nil }.map(\.id) }

    /// The tree. A fork hangs under the attempt it was forked from when that is an attempt shown here, else under the
    /// branch that owns its fork point; a branch whose owner is missing, or that was never forked, is an approach of
    /// the problem. Salvaged lemmas hang under their attempt. With dead ends hidden, a dead end is still shown while
    /// something below it is not a dead end, or a lemma was salvaged from it.
    static func make(problemID: UUID, title: String, theorem: String?, theoremStatus: StatementStatus?,
                     branches: [BranchFacts], attempts: [AttemptFacts], lemmas: [LemmaFacts],
                     showsDeadEnds: Bool) -> BranchTree {
        let byID = Dictionary(branches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let attemptIDs = Set(attempts.map(\.id))
        let attemptsOf = Dictionary(grouping: attempts, by: \.branchID).mapValues { inOrder($0, \.createdAt, \.id) }
        let lemmasOf = Dictionary(grouping: lemmas, by: \.attemptID).mapValues { inOrder($0, \.createdAt, \.id) }
        var forksOfAttempt: [UUID: [BranchFacts]] = [:]
        var forksOfBranch: [UUID: [BranchFacts]] = [:]
        var roots: [BranchFacts] = []
        for branch in inOrder(branches, \.createdAt, \.id) {
            if let attempt = branch.forkAttemptID, attemptIDs.contains(attempt) {
                forksOfAttempt[attempt, default: []].append(branch)
            } else if let owner = branch.forkOwnerID, byID[owner] != nil, owner != branch.id {
                forksOfBranch[owner, default: []].append(branch)
            } else {
                roots.append(branch)
            }
        }

        // Whether a branch is shown when dead ends are hidden: it is not one, or something below it must be shown.
        var kept: [UUID: Bool] = [:]
        func keeps(_ branch: BranchFacts, visiting: Set<UUID>) -> Bool {
            if let known = kept[branch.id] { return known }
            guard !visiting.contains(branch.id) else { return false }
            let visiting = visiting.union([branch.id])
            let own = attemptsOf[branch.id] ?? []
            let below = (forksOfBranch[branch.id] ?? []) + own.flatMap { forksOfAttempt[$0.id] ?? [] }
            let result = showsDeadEnds || branch.state != .deadEnd
                || own.contains { !(lemmasOf[$0.id] ?? []).isEmpty }
                || below.contains { keeps($0, visiting: visiting) }
            kept[branch.id] = result
            return result
        }

        var nodes = [Node(id: problemID, depth: 0, parentID: nil,
                          kind: .problem(title: title, theorem: theorem, status: theoremStatus,
                                         partialProof: attempts.contains { $0.isAdopted && $0.isPartial }),
                          link: nil)]
        var visited: Set<UUID> = []
        func emit(_ branch: BranchFacts, depth: Int, parent: UUID, link: Link) {
            guard keeps(branch, visiting: []), visited.insert(branch.id).inserted else { return }
            nodes.append(Node(id: branch.id, depth: depth, parentID: parent, kind: .branch(branch), link: link))
            for attempt in attemptsOf[branch.id] ?? [] {
                nodes.append(Node(id: attempt.id, depth: depth + 1, parentID: branch.id, kind: .attempt(attempt),
                                  link: .attempt))
                for lemma in lemmasOf[attempt.id] ?? [] {
                    nodes.append(Node(id: lemma.id, depth: depth + 2, parentID: attempt.id, kind: .lemma(lemma),
                                      link: .salvaged))
                }
                for fork in forksOfAttempt[attempt.id] ?? [] { emit(fork, depth: depth + 2, parent: attempt.id, link: .fork) }
            }
            for fork in forksOfBranch[branch.id] ?? [] { emit(fork, depth: depth + 1, parent: branch.id, link: .fork) }
        }
        for root in roots { emit(root, depth: 1, parent: problemID, link: .approach) }
        let hidden = branches.filter { $0.state == .deadEnd && !visited.contains($0.id) && !(kept[$0.id] ?? false) }.count
        return BranchTree(nodes: nodes, hiddenDeadEnds: showsDeadEnds ? 0 : hidden)
    }

    /// Items in the canonical order: by time, ties broken by ID (`BranchHistory.precedes`).
    private static func inOrder<T>(_ items: [T], _ date: KeyPath<T, Date>, _ id: KeyPath<T, UUID>) -> [T] {
        items.sorted { BranchHistory.precedes(($0[keyPath: date], $0[keyPath: id]), ($1[keyPath: date], $1[keyPath: id])) }
    }
}
