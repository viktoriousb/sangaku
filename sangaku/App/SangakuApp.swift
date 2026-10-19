import SwiftUI

@main
struct SangakuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = SangakuApp.makeState()

    /// Debug builds launched with `-SangakuFixture YES` open the mockups' example in memory and never touch the
    /// store, the Keychain or the network. Add `-SangakuDemoReplies YES` to have replies streamed from a canned
    /// answer. `-SangakuFixtureLive YES` instead opens the example with the real Keychain and network, to try real
    /// prompts on it; the store stays in memory. `-SangakuDemoSend <text>` sends one message a second after
    /// launch, `-SangakuDemoFanOut <text>` sends it to A and B refereed by C (add `-SangakuDemoShared YES` for a
    /// shared fan-out), and `-SangakuDemoDraft <text>` starts with a draft in the composer.
    private static func makeState() -> AppState {
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        let arguments = CommandLine.arguments
        if let services = PreviewFixtures.Services.from(arguments: arguments) {
            let fixture = PreviewFixtures.make(services: services)
            if let flag = arguments.firstIndex(of: "-SangakuDemoSend"), flag + 1 < arguments.count {
                fixture.scheduleSend(arguments[flag + 1])
            }
            if let flag = arguments.firstIndex(of: "-SangakuDemoFanOut"), flag + 1 < arguments.count {
                fixture.scheduleSend(arguments[flag + 1],
                                     fanOut: arguments.contains("-SangakuDemoShared") ? .shared : .independent)
            }
            if let flag = arguments.firstIndex(of: "-SangakuDemoDraft"), flag + 1 < arguments.count {
                fixture.state.threads.draft(for: fixture.mainBranch.stableID).text = arguments[flag + 1]
            }
            return fixture.state
        }
        #endif
        return AppState()
    }

    var body: some Scene {
        WindowGroup(id: "workspace") {
            WindowRoot()
                .environment(\.mathRenderer, app.renderer)
                .environment(\.problemManager, app.problems)
                .environment(\.saveScheduler, app.saves)
                .environment(\.threadManager, app.threads)
                .environment(\.statementGraph, app.graph)
                .environment(\.reviewManager, app.reviews)
                .environment(\.credentialManager, app.credentials)
                .onAppear {
                    delegate.saves = app.saves
                    delegate.threads = app.threads
                }
        }
        .modelContainer(app.container)
        .defaultSize(width: 1280, height: 860)
        // A launch always shows a window, even when the last session ended with its window closed and macOS
        // would otherwise restore none.
        .defaultLaunchBehavior(.presented)
        // The window's minimum follows its content's (`WindowRoot.minimumWidth(inspector:)`).
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            SangakuCommands(problems: app.problems)
            ReviewCommands()
        }

        Settings {
            SettingsView()
                .environment(\.credentialManager, app.credentials)
        }
    }
}
