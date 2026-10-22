import AppKit
import SwiftData
import SwiftUI

/// The composition root: created once per app launch and shared by every window.
final class AppState {
    let container: ModelContainer
    let saves: SaveScheduler
    let renderer: MathRenderer
    let problems: ProblemManager
    let graph: StatementGraph
    let reviews: ReviewManager
    let alignments: AlignmentService
    let credentials: CredentialManager
    let threads: ThreadManager
    let branches: BranchManager
    let toolSettings: ToolSettings
    let tools: ToolRunner
    let lean: LeanService
    let compute: ComputeService
    let citations: CitationService
    let export: ExportService

    private var observers: [NSObjectProtocol] = []

    /// Hosted tests run inside the app; they must never touch the real store.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// `secrets`, `transport`, `executor` and `toolStorage` default to the real Keychain, network, processes and
    /// preferences only for the real store; tests, previews and the fixture get an in-memory store, no network, no
    /// tools and settings in memory.
    init(storage: ModelContainerFactory.Storage? = nil, secrets: (any SecretStore)? = nil,
         transport: (any HTTPTransport)? = nil, executor: (any ToolExecuting)? = nil,
         toolStorage: ToolSettings.Storage? = nil, lookupTransport: (any HTTPTransport)? = nil) {
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
        alignments = AlignmentService(context: container.mainContext, saves: saves, problems: problems)
        // Problems from before Milestone 4 get their theorem; an empty store stays empty.
        problems.ensurePinnedTheorems()

        let isLive = if case .disk = resolved, !Self.isRunningTests { true } else { false }
        let secretStore = secrets ?? (isLive ? KeychainSecretStore() : InMemorySecretStore())
        let httpTransport = transport ?? (isLive ? URLSessionTransport.standard() : UnavailableTransport())
        credentials = CredentialManager(store: secretStore)
        threads = ThreadManager(
            context: container.mainContext, saves: saves, problems: problems, credentials: credentials,
            registry: ProviderRegistry([AnthropicProvider(transport: httpTransport, secrets: secretStore)]))
        branches = BranchManager(context: container.mainContext, saves: saves, problems: problems, statements: graph,
                                 activity: threads)

        let workRoot = isLive
            ? URL.applicationSupportDirectory.appending(path: "sangaku").appending(path: "Work")
            : FileManager.default.temporaryDirectory.appending(path: "sangaku-work-" + UUID().uuidString)
        toolSettings = ToolSettings(storage: toolStorage ?? (isLive ? .preferences : .memory()))
        tools = ToolRunner(executor: executor ?? (isLive ? ProcessExecutor(runningFolder: workRoot.appending(path: "running"))
                                                         : RefusingExecutor()),
                           workRoot: workRoot)
        // A crash may have left a check or a computation running, and its folder: stop it and clear them before
        // anything else starts.
        if isLive {
            ProcessExecutor.reapOrphans(in: tools.runningFolder)
            tools.removeLeftoverRunFolders()
        }
        lean = LeanService(context: container.mainContext, saves: saves, problems: problems, tools: tools,
                           settings: toolSettings, announce: VoiceOver.announce)
        lean.refreshWorkspace()
        compute = ComputeService(context: container.mainContext, saves: saves, problems: problems, tools: tools,
                                 settings: toolSettings, announce: VoiceOver.announce)
        let lookups = lookupTransport ?? (isLive ? URLSessionTransport.lookups() : UnavailableTransport())
        citations = CitationService(context: container.mainContext, saves: saves, problems: problems,
                                    client: CitationLookupClient(transport: lookups), announce: VoiceOver.announce)
        export = ExportService(context: container.mainContext, problems: problems, tools: tools,
                               settings: toolSettings, renderer: renderer, announce: VoiceOver.announce)
        problems.willDelete = { [threads, tools, lean, compute, export] problemID in
            threads.cancelAll(problemID: problemID)
            lean.stopCheck(problem: problemID)
            compute.cancelAll(problemID: problemID)
            export.cancelAll(problemID: problemID)
            tools.cancelAll(problemID: problemID)
        }

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
    var tools: ToolRunner?

    /// Saves first and asks if that failed, so Don't Quit leaves everything running; only then stops replies (kept as
    /// interrupted) and tools, and saves what stopping changed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saves?.flush()
        if let error = saves?.lastError, !Self.quitAnyway(error) { return .terminateCancel }
        threads?.stopAllForQuit()
        tools?.stopAllForQuit()
        saves?.flush()
        return .terminateNow
    }

    private static func quitAnyway(_ error: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Your latest changes could not be saved."
        alert.informativeText = error
        alert.addButton(withTitle: "Don't Quit")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

extension View {
    /// Every app-wide manager, as each window, preview and test host needs them. The one list to extend.
    func appEnvironment(_ state: AppState) -> some View {
        environment(\.mathRenderer, state.renderer)
            .environment(\.problemManager, state.problems)
            .environment(\.saveScheduler, state.saves)
            .environment(\.threadManager, state.threads)
            .environment(\.statementGraph, state.graph)
            .environment(\.reviewManager, state.reviews)
            .environment(\.alignmentService, state.alignments)
            .environment(\.branchManager, state.branches)
            .environment(\.credentialManager, state.credentials)
            .environment(\.toolSettings, state.toolSettings)
            .environment(\.leanService, state.lean)
            .environment(\.computeService, state.compute)
            .environment(\.exportService, state.export)
            .environment(\.citationService, state.citations)
    }
}
