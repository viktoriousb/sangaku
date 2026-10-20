import Foundation

/// What can be done to a branch now, and why not. Every place that offers branch actions (the sidebar's menu, the
/// tree's node menu, the Branches panel and the Branches menu) reads this, and it refuses on the same terms as
/// `BranchManager`.
nonisolated struct BranchOffers: Hashable, Sendable {
    nonisolated enum Action: CaseIterable, Hashable, Sendable {
        case newBranch, reopen, editReasons, markDeadEnd, park, cherryPick

        var title: String {
            switch self {
            case .newBranch: "New Branch from Latest Message…"
            case .reopen: "Reopen Branch"
            case .editReasons: "Edit Reasons…"
            case .markDeadEnd: "Mark as Dead End…"
            case .park: "Park…"
            case .cherryPick: "Cherry-pick a Step…"
            }
        }

        /// Opens a sheet that names who wrote what (`BranchIntent.waitsWhileBlind`).
        var waitsWhileBlind: Bool { self != .reopen }

        func intent(_ branchID: UUID) -> BranchIntent {
            switch self {
            case .newBranch: .newBranch(branchID: branchID)
            case .reopen: .reopen(branchID: branchID)
            case .editReasons: .editReasons(branchID: branchID)
            case .markDeadEnd: .markDeadEnd(branchID: branchID)
            case .park: .park(branchID: branchID)
            case .cherryPick: .cherryPick(branchID: branchID)
            }
        }
    }

    var state: BranchState
    var isMain: Bool
    var isRunning: Bool
    var hasMessages: Bool
    /// The branch has an attempt of its own read as steps and finished (`Branch.finishedAttempts`).
    var hasAttempts: Bool
    /// Blind mode hides the authors in Compare: sheets that name them wait (invariant 9).
    var hidesAuthors = false

    /// Whether the action belongs in a menu for this branch at all (reopening a live branch does not).
    func applies(_ action: Action) -> Bool {
        switch action {
        case .markDeadEnd: state != .deadEnd
        case .park: state != .parked
        case .reopen, .editReasons: state.isClosed
        case .newBranch, .cherryPick: true
        }
    }

    /// Why the action would be refused now, or nil.
    func refusal(_ action: Action) -> BranchError? {
        if hidesAuthors, action.waitsWhileBlind { return .blind }
        return switch action {
        case .markDeadEnd, .park:
            isMain ? .isMainLine : isRunning ? .branchBusy : nil
        case .reopen, .editReasons:
            state.isClosed ? nil : .notClosed
        case .newBranch:
            // While a request runs, the latest message is still being written.
            !hasMessages ? .noMessageToForkFrom : isRunning ? .messageStillRunning : nil
        case .cherryPick:
            hasAttempts ? nil : .nothingToCherryPick
        }
    }

    func allows(_ action: Action) -> Bool { applies(action) && refusal(action) == nil }

    /// The actions that apply, in menu order.
    var actions: [Action] { Action.allCases.filter(applies) }

    /// Why the actions shown are disabled, each said once: a disabled button takes no focus, so its reason is shown in
    /// words too.
    var refusals: [String] {
        var seen: [String] = []
        for action in actions {
            if let message = refusal(action)?.message, !seen.contains(message) { seen.append(message) }
        }
        return seen
    }
}

extension Branch {
    /// The branch's own attempts read as steps and finished: what a step can be cherry-picked from.
    func finishedAttempts(live: Set<UUID>) -> [ProofAttempt] {
        sortedMessages.filter { !live.contains($0.stableID) }.compactMap(\.proofAttempt).filter { !($0.steps ?? []).isEmpty }
    }
}

extension BranchOffers {
    /// The offers for a branch as the store and the running requests have it.
    init(_ branch: Branch, mainBranchID: UUID?, streaming: Set<UUID>, live: Set<UUID>, hidesAuthors: Bool) {
        self.init(state: branch.state, isMain: branch.stableID == mainBranchID,
                  isRunning: streaming.contains(branch.stableID), hasMessages: !branch.visibleHistory.all.isEmpty,
                  hasAttempts: !branch.finishedAttempts(live: live).isEmpty, hidesAuthors: hidesAuthors)
    }
}
