import SwiftUI

/// The Review menu: the step-list keys as menu items, for discovery and for when the keyboard is elsewhere. No item
/// has a key equivalent: a plain-letter shortcut would act while someone types.
struct ReviewCommands: Commands {
    @FocusedValue(\.reviewControl) private var control

    var body: some Commands {
        CommandMenu("Review") {
            Button("Next Step") { control?(.command(.next)) }
                .disabled(control?.hasSteps != true)
            Button("Previous Step") { control?(.command(.previous)) }
                .disabled(control?.hasSteps != true)
            Divider()
            ForEach(ReviewVerdict.allCases, id: \.self) { verdict in
                Button("Mark Step \(verdict.title)") { control?(.command(.mark(verdict))) }
                    .disabled(control?.currentStepID == nil)
            }
            Divider()
            Button("Comment on Step") { control?(.command(.comment)) }
                .disabled(control?.currentStepID == nil)
            Button("Revise Step…") { control?(.revise) }
                .disabled(control?.currentStepID == nil)
        }
    }
}
