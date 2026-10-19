import SwiftUI

/// Menu commands. They act on the key window through `FocusedValues.windowState`.
struct SangakuCommands: Commands {
    let problems: ProblemManager
    @FocusedValue(\.windowState) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Problem") { window?.createProblem(using: problems) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(window == nil)
            Button("New Window") { openWindow(id: "workspace") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }

        CommandGroup(after: .sidebar) {
            ForEach(WorkspaceView.allCases) { view in
                Button(view.title) { window?.activeView = view }
                    .keyboardShortcut(view.shortcut, modifiers: .command)
                    .disabled(window == nil)
            }
            Divider()
            Button(window?.inspectorPresented == true ? "Hide Proof Structure" : "Show Proof Structure") {
                window?.inspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(window == nil)
            Button(window?.blindMode == true ? "Turn Blind Mode Off" : "Turn Blind Mode On") {
                window?.blindMode.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(window == nil)
        }
    }
}
