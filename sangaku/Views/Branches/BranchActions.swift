import SwiftUI

/// What a screen asks of branches, through the window's `branchActions` (every value by stable ID, so the handler
/// reads nothing from the render that made it). Sheets open in `BranchSheetHost`; the rest acts at once.
nonisolated enum BranchIntent: Hashable, Sendable {
    /// Opens New Branch on a message.
    case fork(messageID: UUID)
    /// Opens New Branch on the latest message the branch shows.
    case newBranch(branchID: UUID)
    case markDeadEnd(branchID: UUID)
    case park(branchID: UUID)
    case editReasons(branchID: UUID)
    case reopen(branchID: UUID)
    /// Shows the branch in Thread, Review and Compare, whichever is showing.
    case show(branchID: UUID)
    /// The same, and switches to the thread.
    case openMessages(branchID: UUID)
    case showInBranches(UUID)
    case adopt(attemptID: UUID)
    case cherryPick(branchID: UUID)
    /// Shows a statement in the proof-structure inspector.
    case revealStatement(UUID)
    /// Opens the problem editor for the problem shown.
    case editProblem

    /// Opens a sheet that names who wrote what, so it waits while blind mode hides the authors (invariant 9). Adopt
    /// is offered only where the authors are already shown (`CompareAdoption`).
    var waitsWhileBlind: Bool {
        switch self {
        case .fork, .newBranch, .markDeadEnd, .park, .editReasons, .cherryPick: true
        case .reopen, .show, .openMessages, .showInBranches, .adopt, .revealStatement, .editProblem: false
        }
    }
}

/// How the reason sheet opens.
nonisolated enum ReasonMode: Hashable, Sendable {
    case deadEnd, park, edit
}

/// A sheet about branches, open in one window.
nonisolated enum BranchSheet: Hashable, Sendable, Identifiable {
    case newBranch(fromMessage: UUID)
    case reasons(branchID: UUID, mode: ReasonMode)
    case adopt(attemptID: UUID)
    case cherryPick(PromotionTarget)

    var id: Self { self }

    /// Names who wrote what (message authors, the attempt picker), so it is not shown while blind mode hides them.
    var waitsWhileBlind: Bool {
        if case .adopt = self { false } else { true }
    }
}

/// The one handler of branch intents: sheets open in the window, the rest acts at once. It finds branches through
/// the manager when it runs, never through the problem a render had, so a handler kept across a problem switch still
/// acts on the right one.
enum BranchIntentHandler {
    static func perform(_ intent: BranchIntent, window: WindowState, branches: BranchManager?) {
        guard let branches else { return }
        if intent.waitsWhileBlind, window.hidesModelChrome {
            return VoiceOver.announce(BranchError.blind.message)
        }
        switch intent {
        case .fork(let messageID):
            window.branchSheet = .newBranch(fromMessage: messageID)
        case .newBranch(let id):
            guard let latest = branches.branch(id)?.visibleHistory.all.last else {
                return VoiceOver.announce(BranchError.noMessageToForkFrom.message)
            }
            window.branchSheet = .newBranch(fromMessage: latest.stableID)
        case .markDeadEnd(let id):
            window.branchSheet = .reasons(branchID: id, mode: .deadEnd)
        case .park(let id):
            window.branchSheet = .reasons(branchID: id, mode: .park)
        case .editReasons(let id):
            window.branchSheet = .reasons(branchID: id, mode: .edit)
        case .reopen(let id):
            guard let target = branches.branch(id) else { return }
            do throws(BranchError) {
                try branches.reopen(target)
                VoiceOver.announce("\(target.name) reopened")
            } catch {
                VoiceOver.announce(error.message)
            }
        case .show(let id):
            window.switchBranch(to: id)
        case .openMessages(let id):
            window.openMessages(of: id)
        case .showInBranches(let id):
            // A hidden dead end is shown, so the screen opens on it rather than on the problem.
            if branches.branch(id)?.state == .deadEnd { window.showsDeadEnds = true }
            window.showInBranches(id)
        case .adopt(let attemptID):
            window.branchSheet = .adopt(attemptID: attemptID)
        case .revealStatement(let id):
            window.reveal(statement: id)
        case .editProblem:
            window.isEditingProblem = true
        case .cherryPick(let id):
            guard let target = branches.branch(id) else { return }
            do throws(BranchError) {
                window.branchSheet = .cherryPick(try branches.cherryPickTarget(of: target))
            } catch {
                VoiceOver.announce(error.message)
            }
        }
    }
}

/// What the Branches menu asks of the key window's Branches screen.
nonisolated enum BranchesMenuCommand: Hashable, Sendable {
    case next, previous
    case intent(BranchIntent)
}

/// The Branches menu's handle on the key window's Branches screen. Compared by everything its closure reads (the
/// nodes in order, the selection, its branch and what can be done with it), so the closure is never older than what
/// the menu acts on.
nonisolated struct BranchesControl: Equatable, Sendable {
    let presenter: UUID
    let nodes: [UUID]
    let current: UUID?
    let branchID: UUID?
    let offers: BranchOffers?
    let perform: @MainActor (BranchesMenuCommand) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presenter == rhs.presenter && lhs.nodes == rhs.nodes && lhs.current == rhs.current
            && lhs.branchID == rhs.branchID && lhs.offers == rhs.offers
    }

    @MainActor func callAsFunction(_ command: BranchesMenuCommand) { perform(command) }

    func allows(_ action: BranchOffers.Action) -> Bool { offers?.allows(action) ?? false }
}
