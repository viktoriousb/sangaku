import AppKit
import SwiftData

/// The composition root: created once per app launch and shared by every window.
final class AppState {
    let container: ModelContainer
    let saves: SaveScheduler
    let renderer: MathRenderer
    let problems: ProblemManager
    let graph: StatementGraph
    let reviews: ReviewManager
    let credentials: CredentialManager
    let threads: ThreadManager

    private var observers: [NSObjectProtocol] = []

    /// Hosted tests run inside the app; they must never touch the real store.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// `secrets` and `transport` default to the real Keychain and network only for the real store; tests,
    /// previews and the fixture get an in-memory store and no network.
    init(storage: ModelContainerFactory.Storage? = nil, secrets: (any SecretStore)? = nil,
         transport: (any HTTPTransport)? = nil) {
        let resolved: ModelContainerFactory.Storage
        if let storage {
            resolved = storage
        } else if Self.isRunningTests {
            resolved = .inMemory
        } else {
            do {
                resolved = .disk(try ModelContainerFactory.defaultStoreURL())
            } catch {
                Self.stopLaunch(reason: "sangaku cannot create its data folder in Application Support.",
                                detail: error.localizedDescription)
            }
        }
        do {
            container = try ModelContainerFactory.make(resolved)
        } catch {
            var detail = error.localizedDescription
            if case .disk(let url) = resolved { detail += "\n\nStore: \(url.path(percentEncoded: false))" }
            Self.stopLaunch(reason: "sangaku cannot open its data store. Nothing was changed or deleted.", detail: detail)
        }
        saves = SaveScheduler(context: container.mainContext)
        renderer = MathRenderer.standard()
        problems = ProblemManager(context: container.mainContext, saves: saves)
        graph = StatementGraph(context: container.mainContext, saves: saves, problems: problems)
        reviews = ReviewManager(context: container.mainContext, saves: saves, problems: problems)
        // Problems from before Milestone 4 get their theorem; an empty store stays empty.
        problems.ensurePinnedTheorems()

        let isLive = if case .disk = resolved, !Self.isRunningTests { true } else { false }
        let secretStore = secrets ?? (isLive ? KeychainSecretStore() : InMemorySecretStore())
        let httpTransport = transport ?? (isLive ? URLSessionTransport.standard() : UnavailableTransport())
        credentials = CredentialManager(store: secretStore)
        threads = ThreadManager(
            context: container.mainContext, saves: saves, problems: problems, credentials: credentials,
            registry: ProviderRegistry([AnthropicProvider(transport: httpTransport, secrets: secretStore)]))
        problems.willDelete = { [threads] problemID in threads.cancelAll(problemID: problemID) }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [saves] _ in
            MainActor.assumeIsolated { saves.flush() }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Explains why the app cannot start, then quits. Never deletes or replaces a store that fails to open.
    private static func stopLaunch(reason: String, detail: String) -> Never {
        if !isRunningTests {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = reason
            alert.informativeText = detail
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
        fatalError("\(reason) \(detail)")
    }
}

/// Keeps streaming replies as interrupted and saves before quitting, and asks instead of dropping changes that
/// cannot be saved.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var saves: SaveScheduler?
    var threads: ThreadManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        threads?.stopAllForQuit()
        guard let saves else { return .terminateNow }
        saves.flush()
        guard let error = saves.lastError else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Your latest changes could not be saved."
        alert.informativeText = error
        alert.addButton(withTitle: "Don't Quit")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
