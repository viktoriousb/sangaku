import SwiftUI

/// "New Branch from Here…" in a message's context menu. A message still being written cannot be forked from yet.
struct ForkMenuItem: View {
    let message: Message
    let running: Bool

    @Environment(\.branchActions) private var actions

    var body: some View {
        Divider()
        Button("New Branch from Here…") { actions?(.fork(messageID: message.stableID)) }
            .disabled(actions == nil || running)
    }
}

extension View {
    /// "New Branch from Here…" for VoiceOver, as in the message's context menu.
    func forkAction(message: Message, running: Bool, actions: BranchActions?) -> some View {
        accessibilityActions {
            if let actions, !running {
                Button("New Branch from Here") { actions(.fork(messageID: message.stableID)) }
            }
        }
    }
}
