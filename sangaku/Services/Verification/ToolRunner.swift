import Foundation

/// Runs sandboxed jobs for the services that own them, and knows what is running so it can be shown and stopped. The
/// services start and await jobs; quitting and deleting a problem stop them here. Every run gets a fresh folder of its
/// own under the work folder, removed when the run is over.
@Observable
final class ToolRunner {
    nonisolated struct Active: Hashable, Sendable {
        var key: JobKey
        var problemID: UUID?
        var startedAt: Date
    }

    /// Changes only when a job starts or ends.
    private(set) var active: [JobKey: Active] = [:]

    @ObservationIgnored let executor: any ToolExecuting
    /// Where run folders and pid files live.
    @ObservationIgnored let workRoot: URL
    @ObservationIgnored private var tasks: [JobKey: Task<RunReport, Never>] = [:]
    @ObservationIgnored private let now: () -> Date

    init(executor: any ToolExecuting, workRoot: URL, now: @escaping () -> Date = { .now }) {
        self.executor = executor
        self.workRoot = workRoot
        self.now = now
    }

    isolated deinit {
        tasks.values.forEach { $0.cancel() }
    }

    /// The pid files of running jobs (`ProcessExecutor.reapOrphans`).
    var runningFolder: URL { workRoot.appending(path: "running") }

    func isRunning(_ key: JobKey) -> Bool { active[key] != nil }

    /// Runs a job and returns how it ended. A second job with the key of one still running is refused.
    func run(_ job: SandboxJob, onOutput: (@Sendable (String) -> Void)? = nil) async -> RunReport {
        guard active[job.key] == nil else { return .couldNotStart("This is already running.", at: now()) }
        active[job.key] = Active(key: job.key, problemID: job.problemID, startedAt: now())
        let task = Task { [executor] in await executor.execute(job, onOutput: onOutput) }
        tasks[job.key] = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        active[job.key] = nil
        tasks[job.key] = nil
        return report
    }

    func stop(_ key: JobKey) {
        tasks[key]?.cancel()
    }

    /// Stops every job of a problem being deleted.
    func cancelAll(problemID: UUID) {
        for (key, job) in active where job.problemID == problemID { tasks[key]?.cancel() }
    }

    /// Stops everything at once: the app is quitting and will not wait.
    func stopAllForQuit() {
        tasks.values.forEach { $0.cancel() }
        executor.killAll()
    }

    /// A new, empty folder for one run: `Work/P<problem>/run-<id>`, or `Work/shared/run-<id>`.
    func newRunFolder(problem: UUID?) -> String {
        let parent = problem.map { "P" + LeanNaming.short($0) } ?? "shared"
        return workRoot.appending(path: parent).appending(path: "run-" + UUID().uuidString.lowercased()).path
    }

    func removeRunFolder(_ path: String) {
        guard path.hasPrefix(workRoot.path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Removes the run folders a crash or a forced quit left, at launch, before any job starts: every `run-…` folder
    /// under the work folder.
    func removeLeftoverRunFolders() {
        let manager = FileManager.default
        for parent in (try? manager.contentsOfDirectory(atPath: workRoot.path)) ?? [] where parent != "running" {
            let folder = workRoot.appending(path: parent).path
            for run in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] where run.hasPrefix("run-") {
                try? manager.removeItem(atPath: folder + "/" + run)
            }
        }
    }
}
