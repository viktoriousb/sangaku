import SwiftUI

/// Why a sheet's last action failed, under its fields.
struct SheetErrorLine: View {
    let error: String?

    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(ColorToken.refuted.color)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A sheet's Cancel and confirm buttons at its trailing edge: Escape cancels, the shortcut (Return unless given)
/// confirms.
struct SheetButtons: View {
    let confirm: String
    var shortcut = KeyboardShortcut.defaultAction
    var disabled = false
    let action: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(confirm, action: action)
                .keyboardShortcut(shortcut)
                .disabled(disabled)
        }
    }
}
