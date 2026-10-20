import Foundation

/// A branch's messages as models and every screen see them (`BranchHistory`). Only `Branch.visibleHistory` makes
/// one, so no reader assembles a branch's conversation its own way.
nonisolated struct VisibleHistory {
    /// The parent's history up to and including the fork point, oldest first.
    let inherited: [Message]
    /// The branch's own messages, oldest first.
    let own: [Message]
    let fault: BranchHistory.Fault?

    fileprivate init(inherited: [Message], own: [Message], fault: BranchHistory.Fault?) {
        self.inherited = inherited
        self.own = own
        self.fault = fault
    }

    var all: [Message] { inherited + own }
    var ids: [UUID] { all.map(\.stableID) }

    /// Where a message stands in the history, or nil when the branch does not show it.
    func position(of id: UUID) -> Int? { ids.firstIndex(of: id) }
    var inheritedIDs: Set<UUID> { Set(inherited.map(\.stableID)) }

    /// The newest message the branch sees: what a new message must come after.
    var latestDate: Date? { all.map(\.createdAt).max() }
}

extension Branch {
    /// The branch's visible history (`BranchHistory.visible`).
    var visibleHistory: VisibleHistory { visibleHistory(own: nil) }

    /// The same, with this branch's own messages as a view's `@Query` returned them, so the view is told when one is
    /// added; any the query returned from another branch are left out. Only the fork chain is walked.
    func visibleHistory(own queried: [Message]?) -> VisibleHistory {
        var lines: [UUID: BranchHistory.Line] = [:]
        var messages: [UUID: Message] = [:]
        var branch: Branch? = self
        var first = true
        while let current = branch, lines[current.stableID] == nil {
            let own = (first ? queried?.filter { $0.branch?.stableID == current.stableID } ?? current.sortedMessages
                       : current.sortedMessages)
                .sorted { BranchHistory.precedes(($0.createdAt, $0.stableID), ($1.createdAt, $1.stableID)) }
            for message in own { messages[message.stableID] = message }
            lines[current.stableID] = BranchHistory.Line(
                id: current.stableID, forkPoint: current.forkedFrom?.stableID,
                forkOwner: current.forkedFrom?.branch?.stableID,
                wasForked: current.forkedFrom != nil || current.parent != nil, own: own.map(\.stableID))
            branch = current.forkedFrom?.branch
            first = false
        }
        let visible = BranchHistory.visible(stableID, in: lines)
        return VisibleHistory(inherited: visible.inherited.compactMap { messages[$0] },
                              own: visible.own.compactMap { messages[$0] }, fault: visible.fault)
    }
}

extension Problem {
    /// The newest message anywhere in the problem: a person's revision is stamped after it, so no request on any
    /// branch can seem to have seen text written after it was made.
    var latestMessageAt: Date? {
        (branches ?? []).flatMap { $0.messages ?? [] }.map(\.createdAt).max()
    }
}
