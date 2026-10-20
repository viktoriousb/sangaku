import SwiftUI

/// Presents the window's branch sheets and handles branch intents from every screen of the workspace, the sidebar
/// included. Applied once, where the problem is known. While blind mode hides the authors in Compare, no sheet that
/// names them is shown, whoever asked for it (invariant 9).
struct BranchSheetHost: ViewModifier {
    let problem: Problem
    let window: WindowState

    @Environment(\.branchManager) private var branches
    @State private var presenter = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.branchActions, BranchActions(presenter: presenter) { [window, branches] intent in
                BranchIntentHandler.perform(intent, window: window, branches: branches)
            })
            .sheet(item: Binding(get: { Self.presented(in: window) }, set: { window.branchSheet = $0 })) { sheet in
                switch sheet {
                case .newBranch(let messageID):
                    NewBranchSheet(problem: problem, messageID: messageID) { branch in
                        window.openMessages(of: branch.stableID)
                    }
                case .reasons(let branchID, let mode):
                    ReasonSheet(problem: problem, branchID: branchID, mode: mode)
                case .adopt(let attemptID):
                    AdoptSheet(problem: problem, attemptID: attemptID)
                case .cherryPick(let target):
                    // The salvaged lemma is shown, selected, in the proof-structure inspector.
                    PromoteSheet(problem: problem, target: target) { window.reveal(statement: $0) }
                }
            }
    }
}

extension BranchSheetHost {
    /// The sheet shown: the window's, unless it names authors while blind mode hides them.
    static func presented(in window: WindowState) -> BranchSheet? {
        window.branchSheet.flatMap { $0.waitsWhileBlind && window.hidesModelChrome ? nil : $0 }
    }
}

extension View {
    /// The window's branch sheets and intents (`BranchSheetHost`).
    func branchSheets(problem: Problem, window: WindowState) -> some View {
        modifier(BranchSheetHost(problem: problem, window: window))
    }
}
