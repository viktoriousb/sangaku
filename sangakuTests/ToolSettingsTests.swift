import Foundation
import Testing
@testable import sangaku

@Suite("Tools: settings and the runner")
struct ToolSettingsTests {
    @Test("Settings are kept where they are injected, with limits kept within reason")
    func storage() {
        let storage = ToolSettings.Storage.memory()
        let settings = ToolSettings(storage: storage, locator: ToolLocator(isExecutable: { _ in false }))
        settings.update { $0.computeSeconds = 1; $0.leanMemoryGiB = 1_000; $0.leanWorkspace = "/w" }
        #expect(storage.load()?.computeSeconds == 5 && storage.load()?.leanMemoryGiB == 128)
        #expect(ToolSettings(storage: storage).values.leanWorkspace == "/w", "read back from where it was kept")
        #expect(settings.computeLimits.seconds == 5)
    }

    @Test("Tools are found without a shell, never as the system's Python stub; a chosen path must run")
    func locator() {
        let present: Set<String> = ["/usr/local/bin/python3", "/usr/bin/python3", "/opt/tools/gap"]
        let locator = ToolLocator(home: "/Users/someone", isExecutable: { present.contains($0) })
        #expect(locator.resolve(.python, chosen: nil) == .ready(path: "/usr/local/bin/python3", chosen: false))
        #expect(!locator.candidates(.python).contains("/usr/bin/python3"))
        #expect(locator.resolve(.gap, chosen: nil) == .notSetUp)
        #expect(locator.resolve(.gap, chosen: "/opt/tools/gap") == .ready(path: "/opt/tools/gap", chosen: true))
        #expect(locator.resolve(.gap, chosen: "/opt/tools/missing") == .notExecutable("/opt/tools/missing"))
        #expect(locator.resolve(.gap, chosen: "relative/gap") == .notExecutable("relative/gap"))
        #expect(locator.candidates(.elan) == ["/Users/someone/.elan/bin/elan"])
    }

    @Test("A tool's installation may be read, never the whole home folder")
    func installationRoot() {
        let locator = ToolLocator(home: "/Users/someone")
        #expect(locator.installationRoot(of: "/opt/gap-4.13/bin/gap") == "/opt/gap-4.13")
        #expect(locator.installationRoot(of: "/Users/someone/bin/gap") == nil)
        #expect(locator.installationRoot(of: "/Users/gap") == nil)
        #expect(locator.installationRoot(of: "/Users/someone/tools/gap/bin/gap") == "/Users/someone/tools/gap")
        #expect(locator.installationRoot(of: "/Users/someone/Documents/bin/python3") == nil,
                "a program in a folder of the home folder never opens that whole folder")
        #expect(locator.installationRoot(of: "/Users/someone/.local/bin/python3") == "/Users/someone/.local")
    }

    @Test("At launch, the run folders a crash left are removed, and nothing else")
    func leftovers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sangaku-left-\(UUID().uuidString)")
        let runner = ToolRunner(executor: ScriptedExecutor(), workRoot: root)
        let left = runner.newRunFolder(problem: UUID())
        try FileManager.default.createDirectory(atPath: left, withIntermediateDirectories: true)
        let pidFile = runner.runningFolder.appending(path: "1.json")
        try FileManager.default.createDirectory(at: runner.runningFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: pidFile.path, contents: Data())
        runner.removeLeftoverRunFolders()
        #expect(!FileManager.default.fileExists(atPath: left) && FileManager.default.fileExists(atPath: pidFile.path))
    }

    @Test("The runner knows what runs, refuses a second run of the same job, and stops by key, problem or quit")
    func runner() async throws {
        let executor = ScriptedExecutor()
        executor.hold()
        let runner = ToolRunner(executor: executor, workRoot: FileManager.default.temporaryDirectory.appending(path: "w"))
        let job = SandboxJob.testing("/bin/sh", ["-c", "true"], runFolder: "/tmp/r")
        let first = Task { await runner.run(job) }
        try await waitUntil { runner.isRunning(job.key) }
        let second = await runner.run(job)
        guard case .couldNotStart = second.end else {
            Issue.record("a second run of a running job must be refused")
            return
        }
        runner.stop(job.key)
        #expect(await first.value.end == .stopped && !runner.isRunning(job.key))

        // Deleting a problem stops its jobs, and only its jobs.
        let (deleted, kept) = (UUID(), UUID())
        let doomed = SandboxJob.testing("/bin/sh", [], runFolder: "/tmp/r", key: .cell(UUID()), problem: deleted)
        let other = SandboxJob.testing("/bin/sh", [], runFolder: "/tmp/r", key: .cell(UUID()), problem: kept)
        let doomedRun = Task { await runner.run(doomed) }
        let otherRun = Task { await runner.run(other) }
        try await waitUntil { runner.isRunning(doomed.key) && runner.isRunning(other.key) }
        runner.cancelAll(problemID: deleted)
        #expect(await doomedRun.value.end == .stopped && runner.isRunning(other.key))
        runner.stop(other.key)
        _ = await otherRun.value
        runner.stopAllForQuit()
        #expect(executor.killedAll == 1)
        let folder = runner.newRunFolder(problem: UUID())
        #expect(folder.hasPrefix(runner.workRoot.path) && folder.contains("/run-"))
    }

    @Test("A copy of the app that is not the person's own starts no tools")
    func refusing() async {
        let fixture = PreviewFixtures.make()
        #expect(fixture.state.tools.executor is RefusingExecutor)
        let report = await fixture.state.tools.run(.testing("/bin/sh", ["-c", "true"], runFolder: "/tmp/r"))
        guard case .couldNotStart = report.end else {
            Issue.record("the fixture must not run tools")
            return
        }
    }
}
