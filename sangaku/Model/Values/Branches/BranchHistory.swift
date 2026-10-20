import Foundation

/// The one rule for what a branch's conversation is: a fork reads its parent's history up to and including the
/// message it was forked from, then its own messages. Nothing is copied, so stable IDs, `derivedFromIDs` and fan-out
/// grouping stay as they are (invariant 4). What models are sent (`ProblemSnapshot.make`) and what every screen shows
/// come from this function alone, through `Branch.visibleHistory`, so the two cannot disagree.
nonisolated enum BranchHistory {
    /// One branch as the rule needs it.
    nonisolated struct Line: Hashable, Sendable {
        var id: UUID
        /// The message this branch was forked from, and the branch that owns that message.
        var forkPoint: UUID?
        var forkOwner: UUID?
        /// Whether the branch was ever forked: a fork whose point is gone is a fault, never a silent root.
        var wasForked: Bool
        /// This branch's own messages, oldest first.
        var own: [UUID]
    }

    /// Why a fork's earlier history cannot be read. Its own messages still can; nothing is guessed.
    nonisolated enum Fault: Hashable, Sendable {
        case forkPointMissing
        case cycle

        var message: String {
            switch self {
            case .forkPointMissing:
                "This branch was forked from a message that can no longer be found, so its earlier history cannot be read."
            case .cycle:
                "This branch's fork chain loops back on itself, so its earlier history cannot be read."
            }
        }
    }

    nonisolated struct Visible: Hashable, Sendable {
        /// The parent's history up to and including the fork point, oldest first.
        var inherited: [UUID]
        var own: [UUID]
        var fault: Fault?

        var all: [UUID] { inherited + own }

        /// Everything up to and including `id`, or nil when `id` is not visible here.
        func through(_ id: UUID) -> [UUID]? {
            all.firstIndex(of: id).map { Array(all[...$0]) }
        }
    }

    /// The canonical order of messages: by time, ties broken by ID, so every reader agrees.
    static func precedes(_ a: (Date, UUID), _ b: (Date, UUID)) -> Bool {
        (a.0, a.1.uuidString) < (b.0, b.1.uuidString)
    }

    /// The branch's visible history. The cut is by position in the parent's history, never by time. A missing fork
    /// point, a missing owner or a cycle fails closed: the own messages only, with the fault.
    static func visible(_ branch: UUID, in lines: [UUID: Line]) -> Visible {
        var visited: Set<UUID> = []
        return resolve(branch, in: lines, visited: &visited)
    }

    private static func resolve(_ id: UUID, in lines: [UUID: Line], visited: inout Set<UUID>) -> Visible {
        guard let line = lines[id] else { return Visible(inherited: [], own: [], fault: .forkPointMissing) }
        guard visited.insert(id).inserted else { return Visible(inherited: [], own: line.own, fault: .cycle) }
        guard line.wasForked else { return Visible(inherited: [], own: line.own, fault: nil) }
        guard let point = line.forkPoint, let owner = line.forkOwner, lines[owner] != nil else {
            return Visible(inherited: [], own: line.own, fault: .forkPointMissing)
        }
        let parent = resolve(owner, in: lines, visited: &visited)
        if let fault = parent.fault { return Visible(inherited: [], own: line.own, fault: fault) }
        guard let prefix = parent.through(point) else {
            return Visible(inherited: [], own: line.own, fault: .forkPointMissing)
        }
        return Visible(inherited: prefix, own: line.own, fault: nil)
    }
}
