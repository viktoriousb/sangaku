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

/// A sheet's buttons: anything leading at its leading edge, then Cancel, anything else, and the confirm button at its
/// trailing edge. Escape cancels; the shortcut (Return unless given) confirms, and a sheet whose answer must never be
/// one key press away passes none.
struct SheetButtons<Leading: View, Middle: View>: View {
    let confirm: String
    var shortcut: KeyboardShortcut? = .defaultAction
    var disabled = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var middle: Middle
    let action: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            leading
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            middle
            Button(confirm, action: action)
                .keyboardShortcut(shortcut)
                .disabled(disabled)
        }
    }
}

extension SheetButtons where Leading == EmptyView, Middle == EmptyView {
    init(confirm: String, shortcut: KeyboardShortcut? = .defaultAction, disabled: Bool = false,
         action: @escaping () -> Void) {
        self.init(confirm: confirm, shortcut: shortcut, disabled: disabled, leading: { EmptyView() },
                  middle: { EmptyView() }, action: action)
    }
}
