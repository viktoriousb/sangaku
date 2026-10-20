import SwiftUI

/// The Branches menu: moving through the tree, and what can be done with the selected node's branch. No item has a
/// key equivalent: a plain-letter shortcut would act while someone types.
struct BranchesCommands: Commands {
    @FocusedValue(\.branchesControl) private var control
    @FocusedValue(\.windowState) private var window

    var body: some Commands {
        CommandMenu("Branches") {
            Button("Next Node") { control?(.next) }
                .disabled(control?.nodes.isEmpty != false)
            Button("Previous Node") { control?(.previous) }
                .disabled(control?.nodes.isEmpty != false)
            Divider()
            Button("Open Messages") { intent(BranchIntent.openMessages) }
                .disabled(control?.branchID == nil)
            Button("New Branch from Latest Message…") { intent(BranchIntent.newBranch) }
                .disabled(control?.allows(.newBranch) != true)
            Button("Mark as Dead End…") { intent(BranchIntent.markDeadEnd) }
                .disabled(control?.allows(.markDeadEnd) != true)
            Button("Park…") { intent(BranchIntent.park) }
                .disabled(control?.allows(.park) != true)
            Button("Reopen Branch") { intent(BranchIntent.reopen) }
                .disabled(control?.allows(.reopen) != true)
            Button("Edit Reasons…") { intent(BranchIntent.editReasons) }
                .disabled(control?.allows(.editReasons) != true)
            Button("Cherry-pick a Step…") { intent(BranchIntent.cherryPick) }
                .disabled(control?.allows(.cherryPick) != true)
            Divider()
            Toggle("Show Dead Ends", isOn: Binding(
                get: { window?.showsDeadEnds ?? true },
                set: { window?.showsDeadEnds = $0 }))
                .disabled(control == nil)
        }
    }

    private func intent(_ make: (UUID) -> BranchIntent) {
        guard let control, let id = control.branchID else { return }
        control(.intent(make(id)))
    }
}
