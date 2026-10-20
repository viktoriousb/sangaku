import SwiftUI

/// The actions that apply to a branch, each disabled when it would be refused (`BranchOffers`). The same items in the
/// sidebar's menu, the tree's node menu and the Branches panel.
struct BranchActionItems: View {
    let branchID: UUID
    let offers: BranchOffers
    let perform: (BranchIntent) -> Void

    var body: some View {
        ForEach(offers.actions, id: \.self) { action in
            Button(action.title) { perform(action.intent(branchID)) }
                .disabled(!offers.allows(action))
        }
    }
}

/// Why a branch's actions are disabled, in words: a disabled button takes no focus, so its reason would be missed.
struct BranchRefusals: View {
    let offers: BranchOffers

    var body: some View {
        ForEach(offers.refusals, id: \.self) { reason in
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
