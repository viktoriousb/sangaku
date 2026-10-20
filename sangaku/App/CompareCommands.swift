import SwiftUI

/// The Compare menu: the row list's keys as menu items, the filter, and aligning. No item has a key equivalent: a
/// plain-letter shortcut would act while someone types.
struct CompareCommands: Commands {
    @FocusedValue(\.compareControl) private var control
    @FocusedValue(\.windowState) private var window

    var body: some Commands {
        CommandMenu("Compare") {
            Button("Next Row") { control?(.next) }
                .disabled(control?.rows.isEmpty != false)
            Button("Previous Row") { control?(.previous) }
                .disabled(control?.rows.isEmpty != false)
            Divider()
            Toggle("Differences Only", isOn: Binding(
                get: { window?.compareFilter == .differences },
                set: { window?.compareFilter = $0 ? .differences : .all }))
                .disabled(control == nil)
            Button("Align…") { control?(.align) }
                .disabled(control?.canAlign != true)
        }
    }
}
