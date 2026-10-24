import Foundation
import Synchronization
import Testing
@testable import sangaku

/// Passes every job to the real executor, recording git's; the build can be given by the test. The export's commits
/// are real, made in temporary repositories in the name `TestGitHome` gives.
nonisolated final class RecordingExecutor: ToolExecuting {
    typealias BuildHook = @Sendable (SandboxJob) async -> RunReport?

    private let real = ProcessExecutor(runningFolder: nil)
    let gitJobs = Mutex<[SandboxJob]>([])
    /// Called for `build.sh` before it runs; a report it returns stands for the build.
    let build = Mutex<BuildHook?>(nil)

    @concurrent func execute(_ job: SandboxJob, onOutput: (@Sendable (String) -> Void)?) async -> RunReport {
        if job.executable.hasSuffix("/git") { gitJobs.withLock { $0.append(job) } }
        if job.executable == "/bin/sh", let hook = build.withLock({ $0 }), let report = await hook(job) {
            return report
        }
        return await real.execute(job, onOutput: onOutput)
    }

    static func report(_ end: RunEnd, _ stdout: String) -> RunReport {
        RunReport(end: end, stdout: CappedText(text: stdout), stderr: CappedText(text: ""), startedAt: .now, seconds: 0)
    }

    func killAll() { real.killAll() }
}

/// A home folder whose git configuration names a test person: exports commit in that name, and no test reads the
/// real configuration.
nonisolated enum TestGitHome {
    static let identity = "Test Person <test@example.invalid>"

    /// With `named` false, a home whose configuration names no one.
    static func make(named: Bool = true) throws -> String {
        let home = ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path) + "/sangaku-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let config = named ? "[user]\n\tname = Test Person\n\temail = test@example.invalid\n" : "[core]\n\tquotepath = false\n"
        try Data(config.utf8).write(to: URL(fileURLWithPath: home + "/.gitconfig"))
        return home
    }
}

@MainActor
final class ExportHarness {
    let fixture = PreviewFixtures.make()
    let executor = RecordingExecutor()
    let settings = ToolSettings(storage: .memory())
    let tools: ToolRunner
    let service: ExportService
    let folder: String
    private let work: String
    /// The home whose git configuration the export reads (`TestGitHome`).
    let home: String

    /// The folder the export writes into; with `nested`, one level inside the folder `root` names.
    let root: String

    init(nested: Bool = false, named: Bool = true) throws {
        let temporary = ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path)
        work = temporary + "/sangaku-export-work-\(UUID().uuidString)"
        root = temporary + "/sangaku-export-\(UUID().uuidString)"
        folder = nested ? root + "/paper" : root
        home = try TestGitHome.make(named: named)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        tools = ToolRunner(executor: executor, workRoot: URL(fileURLWithPath: work))
        // The kit bundled with the app, unless a test chooses a folder.
        settings.update { $0.paths[.python] = KitRun.python }
        service = ExportService(context: fixture.state.container.mainContext, problems: fixture.state.problems,
                                tools: tools, settings: settings, renderer: fixture.state.renderer, gitHome: home)
        problem = fixture.problem.stableID
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: work)
        try? FileManager.default.removeItem(atPath: home)
    }

    /// Kept, so a test can still name the problem after deleting it.
    let problem: UUID

    func request(_ kind: ExportKind) -> ExportRequest { ExportRequest(problemID: problem, kind: kind, folder: folder) }

    /// Plans, clicks Export on the plan, and waits for the outcome.
    func export(_ kind: ExportKind) async throws -> ExportOutcome {
        let plan = try await service.plan(request(kind))
        try await service.start(request(kind), shown: plan.digest)
        try await waitUntil(timeout: .seconds(180)) { !self.service.isRunning(problem: self.problem) }
        return try #require(service.outcomes[problem])
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: folder + "/" + path) }

    func read(_ path: String) -> String { (try? String(contentsOfFile: folder + "/" + path, encoding: .utf8)) ?? "" }

    /// Every file in the folder with its bytes, to show nothing changed.
    func contents() -> [String: Data] {
        var out: [String: Data] = [:]
        let walker = FileManager.default.enumerator(atPath: folder)
        while let path = walker?.nextObject() as? String {
            if let data = FileManager.default.contents(atPath: folder + "/" + path) { out[path] = data }
        }
        return out
    }

    /// Waits until the export reaches `phase`.
    func wait(for phase: ExportPhase) async throws {
        try await waitUntil(timeout: .seconds(60)) { self.service.phases[self.problem] == phase }
    }

    /// Starts an export and returns once it runs, without waiting for its end.
    func begin(_ kind: ExportKind) async throws {
        let plan = try await service.plan(request(kind))
        try await service.start(request(kind), shown: plan.digest)
    }

    /// `git init` only: the root becomes a repository with nothing committed.
    func makeRepository() throws {
        _ = try git(["init", "-q"], in: root)
    }

    /// The test's own git, outside the sandbox and with no configuration but the test home's: for setting up a
    /// repository and reading what the export committed, never for committing.
    func git(_ arguments: [String], in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory ?? folder] + arguments
        process.environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "HOME": home]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The repository's commits, newest first, as "author <email>|subject"; none when there is no repository.
    func commits(in directory: String? = nil) throws -> [String] {
        try git(["log", "--format=%an <%ae>|%s"], in: directory).split(separator: "\n").map(String.init)
    }

    /// The paths git tracks, relative to the repository's root.
    func tracked(in directory: String? = nil) throws -> Set<String> {
        Set(try git(["ls-files", "-z"], in: directory).split(separator: "\u{0}").map(String.init))
    }
}

@Suite("Export: the service, end to end", .serialized, .enabled(if: KitRun.available && TeXRun.available))
@MainActor
struct ExportServiceTests {
    @Test("A manuscript export builds, writes and commits the project in the person's name; later ones commit what changed with no step of theirs, and refuse their uncommitted edits")
    func manuscript() async throws {
        let harness = try ExportHarness()
        let first = try await harness.export(.hashtag)
        #expect(first.succeeded, "\(first.error?.message ?? "")")
        #expect(first.report?.isPass == true)
        for path in ["build.sh", ".kit-manifest", "manuscript/main.pdf", "manuscript/ch1-results.tex",
                     "manuscript/htag-registry.tex", ExportManifest.fileName] {
            #expect(harness.exists(path), "\(path)")
        }
        for path in ["manuscript/main.log", "manuscript/main.aux", "manuscript/build.log", HashtagWriter.kitExample] {
            #expect(!harness.exists(path), "\(path) is not copied")
        }
        #expect(harness.read("manuscript/main.tex").contains("% sangaku:begin chapters\n\\input{ch1-results}\n% sangaku:end chapters"))
        let registry = harness.read("manuscript/htag-registry.tex")
        let commit = TestGitHome.identity + "|Export the hashtag manuscript"

        // Put in git and committed in the person's name: every file but the PDF, which is rebuilt from the sources.
        #expect(first.uncommitted == nil, "\(first.uncommitted ?? "")")
        #expect(try harness.commits() == [commit])
        #expect(try harness.tracked().isSuperset(of: ["build.sh", ".gitignore", ".kit-manifest", "manuscript/preface.tex",
                                                      "manuscript/htag-registry.tex", ExportManifest.fileName]))
        #expect(try harness.git(["status", "--porcelain"]) == "?? manuscript/main.pdf\n")

        // Again with nothing changed: nothing to commit.
        let same = try await harness.export(.hashtag)
        #expect(same.succeeded && same.uncommitted == nil, "\(same.error?.message ?? same.uncommitted ?? "")")
        #expect(try harness.commits() == [commit])

        // A new statement: exported and committed; every earlier tag is kept.
        let lemma = Statement(kind: .lemma, label: "Lem 8", statementLaTeX: "A new lemma about $p$.",
                              author: .human(harness.fixture.you.personID))
        harness.fixture.problem.statements = (harness.fixture.problem.statements ?? []) + [lemma]
        let again = try await harness.export(.hashtag)
        #expect(again.succeeded, "\(again.error?.message ?? "")")
        #expect(harness.read("manuscript/ch1-results.tex").contains("Lem 8"))
        #expect(ExportFolder.registryGrows(old: registry, new: harness.read("manuscript/htag-registry.tex")))
        #expect(harness.read("manuscript/htag-registry.tex").count > registry.count, "the new item's tag was added")
        #expect(!again.written.contains("build.sh") && !again.written.contains(".kit-manifest"), "frozen files never copied back")
        #expect(try harness.commits() == [commit, commit])
        #expect(try harness.git(["status", "--porcelain"]) == "?? manuscript/main.pdf\n")

        // An edit of the person's that is not committed: refused, naming it, and kept as it is.
        let edit = harness.read("manuscript/preface.tex") + "% mine\n"
        try Data(edit.utf8).write(to: URL(fileURLWithPath: harness.folder + "/manuscript/preface.tex"))
        let edited = try await harness.export(.hashtag)
        guard case .git(let named) = edited.error else {
            Issue.record("expected an uncommitted edit, got \(String(describing: edited.error))")
            return
        }
        #expect(named.contains("manuscript/preface.tex") && named.contains("Commit or discard"))
        #expect(harness.read("manuscript/preface.tex") == edit)
        #expect(try harness.commits().count == 2)

        // git writes only its run folder and the repository's .git, never the person's files; its status takes no lock.
        let jobs = harness.executor.gitJobs.withLock { $0 }
        #expect(jobs.contains { $0.arguments.contains("init") })
        for job in jobs {
            #expect(job.grants.writable.allSatisfy { !$0.hasPrefix(harness.folder + "/") || $0 == harness.folder + "/.git" },
                    "\(job.arguments)")
        }
        #expect(jobs.filter { $0.arguments.contains("status") }.allSatisfy { $0.arguments.contains("--no-optional-locks") })
    }

    @Test("A kit folder chosen in Settings is used instead of the bundled copy")
    func kitFolder() async throws {
        let harness = try ExportHarness()
        let bundled = try await harness.service.plan(harness.request(.hashtag))
        #expect(bundled.kit?.contains("bundled with the app") == true)
        harness.settings.update { $0.hashtagKit = KitRun.kit }
        let plan = try await harness.service.plan(harness.request(.hashtag))
        #expect(plan.kit == "hashtag 1.0 from " + KitRun.kit && plan.digest != bundled.digest, "the click binds the kit")
        let outcome = try await harness.export(.hashtag)
        #expect(outcome.succeeded, "\(outcome.error?.message ?? "")")
        #expect(harness.read(".kit-version").hasPrefix("hashtag 1.0"))
    }

    @Test("The LaTeX export writes the file and its PDF; the Lean project its package")
    func latexAndLean() async throws {
        let harness = try ExportHarness()
        let latex = try await harness.export(.latex)
        #expect(latex.succeeded, "\(latex.error?.message ?? "")")
        let name = ExportService.latexName(ExportSnapshot.read(problem: harness.fixture.problem,
                                                                people: harness.fixture.state.problems.personIDs()))
        #expect(harness.exists(name + ".tex") && harness.exists(name + ".pdf") && harness.exists(ExportManifest.fileName))
        #expect(try harness.tracked() == [name + ".tex", ExportManifest.fileName], "the PDF is rebuilt from the file")
        #expect(try harness.commits() == [TestGitHome.identity + "|Export the LaTeX file"])

        let other = try ExportHarness()
        let lean = try await other.export(.leanProject)
        #expect(lean.succeeded, "\(lean.error?.message ?? "")")
        #expect(other.exists("lakefile.toml") && other.exists("README.md") && other.exists("lean-toolchain"))
        #expect(try other.commits() == [TestGitHome.identity + "|Export the Lean project"])
        #expect(try other.git(["status", "--porcelain"]).isEmpty)
    }

    @Test("Nothing runs when the plan changed after it was shown, the folder is someone else's, or the kit is missing")
    func refusals() async throws {
        let harness = try ExportHarness()
        let plan = try await harness.service.plan(harness.request(.hashtag))
        harness.fixture.lemmas[0].statementLaTeX += " Changed."
        await #expect(throws: ExportError.changedSinceShown) {
            try await harness.service.start(harness.request(.hashtag), shown: plan.digest)
        }
        #expect(!harness.service.isRunning(problem: harness.problem))

        try Data("mine".utf8).write(to: URL(fileURLWithPath: harness.folder + "/notes.txt"))
        let foreign = try await harness.service.plan(harness.request(.leanProject))
        #expect(foreign.folder.refusal?.contains("holds other files") == true)
        await #expect(throws: ExportError.self) {
            try await harness.service.start(harness.request(.leanProject), shown: foreign.digest)
        }
        try FileManager.default.removeItem(atPath: harness.folder + "/notes.txt")

        harness.settings.update { $0.hashtagKit = NSTemporaryDirectory() }
        let noKit = try await harness.service.plan(harness.request(.hashtag))
        #expect(noKit.kit == nil, "a folder that is not a kit is never used")
        await #expect(throws: ExportError.self) {
            try await harness.service.start(harness.request(.hashtag), shown: noKit.digest)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.folder).isEmpty, "nothing was written")
    }
}

@Suite("Export: what never reaches the folder", .serialized, .enabled(if: KitRun.available && TeXRun.available))
@MainActor
struct ExportFolderSafetyTests {
    nonisolated private static let failing = """
        LaTeX: 1 errors, 0 undefined references, 0 labels defined twice, 0 unresolved links, 0 overfull boxes, 3 pages (3 passes)
        PASS tags (12 in manuscript/htag-index.md)
        PASS frozen files unchanged
        """

    @Test("A build that fails writes nothing: the earlier export stays byte for byte")
    func failedBuild() async throws {
        let harness = try ExportHarness()
        #expect(try await harness.export(.hashtag).succeeded)
        let before = harness.contents()
        harness.executor.build.withLock { $0 = { _ in RecordingExecutor.report(.exited(1), Self.failing) } }
        harness.fixture.lemmas[0].statementLaTeX += " Changed."
        let outcome = try await harness.export(.hashtag)
        guard case .build(let report) = outcome.error else {
            Issue.record("expected a failed build, got \(String(describing: outcome.error))")
            return
        }
        #expect(!report.isPass && report.missing.contains("every item has a label"))
        #expect(harness.contents() == before, "the files and the repository alike")
    }

    @Test("Stop during the build writes nothing; a problem deleted meanwhile keeps no outcome")
    func stopAndDelete() async throws {
        let harness = try ExportHarness()
        harness.executor.build.withLock {
            $0 = { _ in
                try? await Task.sleep(for: .seconds(30))
                return RecordingExecutor.report(.signaled(15), "")
            }
        }
        try await harness.begin(.hashtag)
        try await harness.wait(for: .building)
        harness.service.stop(problem: harness.problem)
        try await waitUntil(timeout: .seconds(30)) { !harness.service.isRunning(problem: harness.problem) }
        #expect(harness.service.outcomes[harness.problem]?.error == .stopped)
        #expect(harness.contents().isEmpty, "the first export wrote nothing")

        try await harness.begin(.hashtag)
        try await harness.wait(for: .building)
        harness.service.cancelAll(problemID: harness.problem)
        harness.fixture.state.container.mainContext.delete(harness.fixture.problem)
        try await waitUntil(timeout: .seconds(30)) { !harness.service.isRunning(problem: harness.problem) }
        #expect(harness.service.outcomes[harness.problem] == nil)
        #expect(harness.contents().isEmpty)
    }

    @Test("A folder that changes while the export runs is not written")
    func changedDuringBuild() async throws {
        let harness = try ExportHarness()
        let folder = harness.folder
        harness.executor.build.withLock {
            $0 = { _ in
                try? Data("mine".utf8).write(to: URL(fileURLWithPath: folder + "/notes.txt"))
                return nil
            }
        }
        let outcome = try await harness.export(.hashtag)
        guard case .folder(let reason) = outcome.error else {
            Issue.record("expected a changed folder, got \(String(describing: outcome.error))")
            return
        }
        #expect(reason.contains("changed while the export ran"))
        #expect(Set(harness.contents().keys) == ["notes.txt"])
    }

    @Test("A program that never ran is named with its reason: the example copy's tools are turned off, and it reads no git configuration")
    func refusedTools() async throws {
        let fixture = PreviewFixtures.make()
        let folder = ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path) + "/sangaku-refused-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let home = try TestGitHome.make()
        defer {
            try? FileManager.default.removeItem(atPath: folder)
            try? FileManager.default.removeItem(atPath: home)
        }
        let problem = fixture.problem.stableID
        if fixture.state.toolSettings.resolution(.git).path != nil {
            let request = ExportRequest(problemID: problem, kind: .leanProject, folder: folder)
            let plan = try await fixture.state.export.plan(request)
            await #expect(throws: ExportError.git("This copy of the app (tests, previews or the fixture) reads no git configuration, so it cannot commit an export.")) {
                try await fixture.state.export.start(request, shown: plan.digest)
            }
        }
        // The same copy, given a home to read: the tools it runs are what refuse.
        let export = ExportService(context: fixture.state.container.mainContext, problems: fixture.state.problems,
                                   tools: fixture.state.tools, settings: fixture.state.toolSettings,
                                   renderer: fixture.state.renderer, gitHome: home)
        for (kind, program) in [(ExportKind.hashtag, "kit.py new"), (.latex, "pdfLaTeX")] {
            let request = ExportRequest(problemID: problem, kind: kind, folder: folder)
            let plan = try await export.plan(request)
            try await export.start(request, shown: plan.digest)
            try await waitUntil(timeout: .seconds(30)) { !export.isRunning(problem: problem) }
            let error = try #require(export.outcomes[problem]?.error)
            #expect(error == .run(program + " could not run: Tools are turned off in this copy of the app."))
            #expect(error.message.hasSuffix("Nothing was written to the folder."))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).isEmpty)
    }

    @Test("A build that never ran is said as such, not as a build that failed its checks")
    func buildNeverRan() async throws {
        let harness = try ExportHarness()
        harness.executor.build.withLock { $0 = { _ in .couldNotStart("The sandbox refused it.", at: .now) } }
        let outcome = try await harness.export(.hashtag)
        #expect(outcome.error == .run("build.sh could not run: The sandbox refused it."))
        #expect(harness.contents().isEmpty)
    }
}

/// Every export keeps its folder in git: real commits, in temporary repositories, in the test home's name.
@Suite("Export: the folder kept in git", .serialized, .enabled(if: KitRun.available && TeXRun.available))
@MainActor
struct ExportGitTests {
    @Test("An export needs git and the person's name in their git configuration, or nothing runs")
    func gitAndIdentity() async throws {
        let harness = try ExportHarness()
        harness.settings.update { $0.paths[.git] = "/nonexistent/git" }
        let plan = try await harness.service.plan(harness.request(.leanProject))
        await #expect(throws: ExportError.git("Exports keep their folder in git, and git is not set up. Set it up in Settings ▸ Export.")) {
            try await harness.service.start(harness.request(.leanProject), shown: plan.digest)
        }

        let nameless = try ExportHarness(named: false)
        let unnamed = try await nameless.service.plan(nameless.request(.leanProject))
        do {
            try await nameless.service.start(nameless.request(.leanProject), shown: unnamed.digest)
            Issue.record("expected a refusal: no one to commit as")
        } catch {
            #expect(error.message.contains("sets no user.name and user.email"), "\(error.message)")
        }
        #expect(harness.contents().isEmpty && nameless.contents().isEmpty)
        #expect(!harness.service.isRunning(problem: harness.problem) && !nameless.service.isRunning(problem: nameless.problem))
    }

    @Test("A folder inside a repository is committed there, and only the export's files: what the person staged stays staged")
    func nestedRepository() async throws {
        let nested = try ExportHarness(nested: true)
        try nested.makeRepository()
        let first = try await nested.export(.leanProject)
        #expect(first.succeeded && first.uncommitted == nil, "\(first.error?.message ?? first.uncommitted ?? "")")
        #expect(!nested.exists(".git"), "no repository inside the repository")
        #expect(try nested.commits(in: nested.root) == [TestGitHome.identity + "|Export the Lean project"])
        #expect(try nested.tracked(in: nested.root).allSatisfy { $0.hasPrefix("paper/") })
        let commit = try #require(nested.executor.gitJobs.withLock { $0 }.last { $0.arguments.contains("commit") })
        #expect(commit.grants.writable.contains(nested.root + "/.git") && commit.grants.readable.first == nested.root)

        try Data("mine\n".utf8).write(to: URL(fileURLWithPath: nested.root + "/notes.txt"))
        _ = try nested.git(["add", "notes.txt"], in: nested.root)
        nested.fixture.problem.title += " again"
        let again = try await nested.export(.leanProject)
        #expect(again.succeeded && again.uncommitted == nil, "\(again.error?.message ?? again.uncommitted ?? "")")
        #expect(try nested.commits(in: nested.root).count == 2)
        #expect(try nested.git(["show", "--name-only", "--format=", "HEAD"], in: nested.root) == "paper/README.md\n")
        #expect(try nested.git(["diff", "--cached", "--name-only"], in: nested.root) == "notes.txt\n")
    }

    @Test("A folder an earlier export wrote before it was in git is committed as it was, the person's edits included, then the export")
    func earlierExportOutsideGit() async throws {
        let harness = try ExportHarness()
        #expect(try await harness.export(.leanProject).succeeded)
        try FileManager.default.removeItem(atPath: harness.folder + "/.git")
        let edited = harness.read("README.md") + "\nMine.\n"
        try Data(edited.utf8).write(to: URL(fileURLWithPath: harness.folder + "/README.md"))
        harness.fixture.problem.title += " again"
        let outcome = try await harness.export(.leanProject)
        #expect(outcome.succeeded && outcome.uncommitted == nil, "\(outcome.error?.message ?? outcome.uncommitted ?? "")")
        #expect(try harness.commits() == [TestGitHome.identity + "|Export the Lean project",
                                          TestGitHome.identity + "|Keep the folder as it was before the export"])
        #expect(try harness.git(["show", "HEAD~1:README.md"]) == edited, "the person's edit is kept in git")
        #expect(harness.read("README.md").contains(" again"))

        // A manuscript: the kit's whole project goes in, as a first export would have put it.
        let manuscript = try ExportHarness()
        #expect(try await manuscript.export(.hashtag).succeeded)
        try FileManager.default.removeItem(atPath: manuscript.folder + "/.git")
        let again = try await manuscript.export(.hashtag)
        #expect(again.succeeded && again.uncommitted == nil, "\(again.error?.message ?? again.uncommitted ?? "")")
        #expect(try manuscript.commits() == [TestGitHome.identity + "|Keep the folder as it was before the export"],
                "the export changed nothing")
        #expect(try manuscript.git(["status", "--porcelain"]) == "?? manuscript/main.pdf\n")
    }

    @Test("A commit that fails leaves the export written and says why, for the person to commit")
    func commitFails() async throws {
        let harness = try ExportHarness(nested: true)
        try harness.makeRepository()
        let hooks = harness.root + "/.git/hooks"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 'refused by the hook' >&2\nexit 1\n".utf8).write(to: URL(fileURLWithPath: hooks + "/pre-commit"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks + "/pre-commit")
        let outcome = try await harness.export(.leanProject)
        #expect(outcome.succeeded && harness.exists("lakefile.toml"), "\(outcome.error?.message ?? "")")
        let reason = try #require(outcome.uncommitted)
        #expect(reason.hasPrefix("git commit ended with status 1") && reason.hasSuffix("Commit the export's files yourself before exporting again."),
                "\(reason)")
        #expect(try harness.commits(in: harness.root).isEmpty)
        #expect(ExportScreenWording.outcome(outcome).contains("It was not committed: git commit ended"))
    }
}

@Suite("Export: the person's git identity")
struct GitIdentityTests {
    @Test("user.name and user.email from a config file: the [user] section only, quotes and comments as git reads them")
    func values() {
        let text = """
            [core]
            \tname = Not This
            [user "work"]
            \temail = not@this.invalid
            [user]
            \tname = "Test  Person" ; a comment
            \temail = test@example.invalid # another
            """
        let values = GitIdentity.userValues(text)
        #expect(values.name == "Test  Person" && values.email == "test@example.invalid")
        #expect(GitIdentity.userValues("[core]\n\tname = x\n").name == nil)
    }

    @Test("Read in git's order, a later file winning; nil without both, or with a hidden character")
    func read() throws {
        let home = try TestGitHome.make(named: false)
        let repository = home + "/repo"
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.config/git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repository + "/.git", withIntermediateDirectories: true)
        func write(_ text: String, _ path: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
        #expect(GitIdentity.read(home: home, repository: nil) == nil)
        try write("[user]\n\tname = First\n\temail = first@example.invalid\n", home + "/.config/git/config")
        try write("[user]\n\temail = second@example.invalid\n", home + "/.gitconfig")
        #expect(GitIdentity.read(home: home, repository: nil) == GitIdentity(name: "First", email: "second@example.invalid"))
        try write("[user]\n\tname = Third\n", repository + "/.git/config")
        #expect(GitIdentity.read(home: home, repository: repository) == GitIdentity(name: "Third", email: "second@example.invalid"))
        try write("[user]\n\tname = Thi\u{202E}rd\n", repository + "/.git/config")
        #expect(GitIdentity.read(home: home, repository: repository) == nil)
    }
}

@Suite("Export: files, regions and reports")
struct ExportPartsTests {
    @Test("git's -z status: every listed path, renames by their new name")
    func gitStatus() {
        let output = " M manuscript/preface.tex\u{0}?? manuscript/refs.bib\u{0}R  manuscript/new.tex\u{0}manuscript/old.tex\u{0}!! .sangaku-export.json\u{0}"
        #expect(ExportFolder.uncommitted(output) == ["manuscript/preface.tex", "manuscript/refs.bib", "manuscript/new.tex",
                                                     ".sangaku-export.json"])
        #expect(ExportFolder.uncommitted("").isEmpty)
    }

    @Test("Regions: a first export replaces the kit's lines; later ones only what lies between the markers")
    func regions() throws {
        let regions = HashtagRegions(title: "\\title{\\bfseries New}\n", chapters: "\\input{ch1-results}\n", notation: "% n\n")
        let kit = "\\documentclass{htag_paper}\n\\title{\\bfseries Exported problem}\n\\begin{document}\n\\input{ch1-setting}\n\\end{document}\n"
        let first = try HashtagWriter.firstMain(kit, regions: regions)
        #expect(first == "\\documentclass{htag_paper}\n% sangaku:begin title\n\\title{\\bfseries New}\n% sangaku:end title\n\\begin{document}\n% sangaku:begin chapters\n\\input{ch1-results}\n% sangaku:end chapters\n\\end{document}\n")
        let edited = first.replacingOccurrences(of: "\\begin{document}", with: "% mine\n\\begin{document}")
        var next = regions
        next.chapters = "\\input{ch1-results}\n\\input{ch2-more}\n"
        let updated = try HashtagWriter.update(edited, file: "main.tex", regions: [("title", next.title), ("chapters", next.chapters)])
        #expect(updated.contains("% mine") && updated.contains("\\input{ch2-more}"))
        #expect(try HashtagWriter.update(updated, file: "main.tex", regions: [("title", next.title), ("chapters", next.chapters)]) == updated)
        #expect(throws: HashtagPatchError.missingMarkers("main.tex")) {
            try HashtagWriter.update(kit, file: "main.tex", regions: [("title", next.title)])
        }
        #expect(throws: HashtagPatchError.unexpectedKitFile("manuscript/main.tex")) {
            try HashtagWriter.firstMain("\\documentclass{x}\n", regions: regions)
        }
        let preamble = HashtagWriter.firstPreamble("\\htagsalt{s}\n", regions: regions)
        #expect(preamble == "\\htagsalt{s}\n\n% sangaku:begin notation\n% n\n% sangaku:end notation\n")
    }

    @Test("build.sh's report passes only with exit 0, no LaTeX problem and every check PASS")
    func buildReport() {
        let good = """
            LaTeX: 0 errors, 0 undefined references, 0 labels defined twice, 0 unresolved links, 2 overfull boxes, 7 pages (3 passes)
            PASS tags (12 in manuscript/htag-index.md)
            PASS frozen files unchanged
            PASS every reference is defined
            PASS no label is defined twice
            PASS every item has a label
            PASS every item lies in a subsection
            """
        let report = BuildReport.read(good, exitedCleanly: true)
        #expect(report.isPass && report.counts?.overfull == 2 && report.counts?.pages == 7)
        #expect(!BuildReport.read(good, exitedCleanly: false).isPass)
        #expect(!BuildReport.read(good.replacingOccurrences(of: "0 undefined", with: "1 undefined"), exitedCleanly: true).isPass)
        let failed = BuildReport.read(good.replacingOccurrences(of: "PASS every item has a label", with: "FAIL every item has a label   lemma ch1:3"),
                                      exitedCleanly: true)
        #expect(!failed.isPass && failed.failed.count == 1)
        let missing = BuildReport.read(good.replacingOccurrences(of: "PASS frozen files unchanged\n", with: ""), exitedCleanly: true)
        #expect(!missing.isPass && missing.missing == ["frozen files unchanged"])
        #expect(!BuildReport.read("nothing", exitedCleanly: true).isPass, "a missing LaTeX line is not a pass")
        let none = BuildReport.read(good.replacingOccurrences(of: "7 pages (3 passes)", with: "no pages (3 passes)"), exitedCleanly: true)
        #expect(none.counts?.pages == nil, "no pages is not an earlier count")
        #expect(BuildReport.annotated("! Undefined control sequence in lem:s1a2b3c4d5e6f.", names: ["1a2b3c4d5e6f": "Lem 1"])
                == "! Undefined control sequence in lem:s1a2b3c4d5e6f (Lem 1).")
    }

    @Test("The tag registry may only grow")
    func registry() {
        let old = "\\htagregistrysalt{s}\n\\htagentry{AB12}{lem:x}\n"
        #expect(ExportFolder.registryGrows(old: old, new: old + "\\htagentry{CD34}{lem:y}\n"))
        #expect(!ExportFolder.registryGrows(old: old, new: "\\htagregistrysalt{s}\n\\htagentry{ZZ99}{lem:x}\n"))
        #expect(!ExportFolder.registryGrows(old: old, new: "\\htagregistrysalt{t}\n\\htagentry{AB12}{lem:x}\n"))
        #expect(ExportFolder.registryGrows(old: "", new: old))
    }

    @Test("The kit: the copy bundled with the app unless a folder is chosen; either only with every file it needs")
    func kit() throws {
        let bundled = try HashtagKit.resolve(nil)
        guard case .bundled(let commit) = bundled.source else {
            Issue.record("no folder chosen: the bundled kit")
            return
        }
        #expect(bundled.version == "1.0" && !commit.isEmpty)
        #expect(throws: ExportError.self) { try HashtagKit.resolve(NSTemporaryDirectory()) }
        #expect(throws: ExportError.kit("The app's bundled hashtag kit is missing. Reinstall sangaku.")) {
            try HashtagKit.resolve(nil, pinned: nil)
        }
        let pinned = try #require(PinnedKit.bundled)
        var broken = pinned
        broken.files.removeAll { $0.path == "template/build.sh" }
        #expect(throws: ExportError.self) { try HashtagKit.resolve(nil, pinned: broken) }
        #expect(pinned.files.filter(\.executable).map(\.path)
                == ["template/build.sh", "template/compile_one.sh", "template/computations/crossref_audit.py"])
        if KitRun.available { #expect(try HashtagKit.resolve(KitRun.kit).source == .folder(KitRun.kit)) }
    }

    @Test("The bundled kit is the kit in the development folder, file for file: if not, re-pin it with scripts/pin-hashtag-kit.py",
          .enabled(if: KitRun.available))
    func pinMatchesKit() throws {
        let pinned = try #require(PinnedKit.bundled)
        let kit = KitRun.kit
        var paths = ["LICENSE", "VERSION", "kit.py", "htag_paper.cls", "htag.sty"]
        let walker = FileManager.default.enumerator(atPath: kit + "/template")
        while let path = walker?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            guard !path.contains(".build"), !path.contains("__pycache__"), !path.hasSuffix(".DS_Store"),
                  FileManager.default.fileExists(atPath: kit + "/template/" + path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            paths.append("template/" + path)
        }
        #expect(Set(pinned.files.map(\.path)) == Set(paths), "the kit's files changed")
        for file in pinned.files {
            #expect(file.contents == (try? String(contentsOfFile: kit + "/" + file.path, encoding: .utf8)), "\(file.path) differs from the kit")
        }
    }

    @Test("Installing the bundled kit writes every pinned file, scripts executable")
    func installBundled() async throws {
        let folder = ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path) + "/sangaku-kit-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try await HashtagKit.install(try HashtagKit.resolve(nil), to: folder)
        let pinned = try #require(PinnedKit.bundled)
        for file in pinned.files {
            #expect(try String(contentsOfFile: folder + "/" + file.path, encoding: .utf8) == file.contents)
            #expect(FileManager.default.isExecutableFile(atPath: folder + "/" + file.path) == file.executable, "\(file.path)")
        }
        #expect(try HashtagKit.resolve(folder).version == pinned.version, "the installed copy is a kit")
    }

    @Test("Folder states: empty or git only is a first export; an earlier export of this problem and kind is updated")
    func folderStates() throws {
        let folder = ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path) + "/sangaku-state-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder + "/.git", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let problem = UUID()
        #expect(ExportFolder.state(folder, kind: .leanProject, problem: problem) == .empty)
        try ExportManifest(kind: .leanProject, problem: problem).data.write(to: URL(fileURLWithPath: folder + "/" + ExportManifest.fileName))
        #expect(ExportFolder.state(folder, kind: .leanProject, problem: problem) == .earlierExport)
        #expect(ExportFolder.state(folder, kind: .latex, problem: problem).refusal != nil)
        #expect(ExportFolder.state(folder, kind: .leanProject, problem: UUID()).refusal == "The folder holds an export of another problem.")
        #expect(ExportFolder.state(folder, kind: .hashtag, problem: problem).refusal != nil)
        #expect(ExportFolder.state("/nonexistent-\(UUID())", kind: .latex, problem: problem).refusal != nil)
        #expect(ExportFolder.repositoryRoot(of: folder) == folder)
    }

    @Test("The export's jobs: each writes only its run folder, reads neither the person's folder nor the kit's, and the build writes exactly the approved files and regions")
    func jobs() throws {
        let problem = UUID()
        let regions = HashtagRegions(title: "\\title{\\bfseries T}\n", chapters: "\\input{ch1-results}\n", notation: "% n\n")
        let request = ExportRequest(problemID: problem, kind: .hashtag, folder: "/Users/someone/papers/p")
        let plan = ExportPlan(request: request, files: [ExportFile(path: "manuscript/preface.tex", contents: "P")],
                              regions: regions, folder: .empty, kit: "1.0")
        let approval = try ExportApproval.given(by: PersonID(UUID()), shown: plan.digest, planned: plan, at: .now)
        let setup = ExportSetup(python: "/opt/homebrew/bin/python3", pythonRoot: "/opt/homebrew/Cellar/python", texBin: "/Library/TeX/texbin")
        let run = "/tmp/run"
        let kit = SandboxJob.exportKit(approval, setup: setup, runFolder: run)
        let build = try SandboxJob.exportBuild(approval, setup: setup, bases: (main: "\\title{\\bfseries x}\n\\input{ch1-setting}\n", preamble: "\\htagsalt{s}\n"),
                                               first: true, runFolder: run)
        let latexPlan = ExportPlan(request: ExportRequest(problemID: problem, kind: .latex, folder: request.folder),
                                   files: [ExportFile(path: "p.tex", contents: "\\documentclass{amsart}")], regions: nil, folder: .empty)
        let latex = SandboxJob.exportLatex(try ExportApproval.given(by: PersonID(UUID()), shown: latexPlan.digest, planned: latexPlan, at: .now),
                                           texBin: setup.texBin, runFolder: run)
        for job in [kit, build, latex] {
            #expect(job.grants.writable == [run])
            #expect(!job.grants.readable.contains { $0.hasPrefix(request.folder) || $0.contains("hashtag") })
            #expect(job.environment["shell_escape"] == "f" && job.environment["PATH"]?.contains("::") == false)
        }
        #expect(kit.arguments.contains(run + "/kit/kit.py") && kit.arguments.contains(HashtagWriter.salt(problem)))
        #expect(build.files.map(\.path) == [run + "/project/manuscript/preface.tex", run + "/project/manuscript/main.tex",
                                            run + "/project/manuscript/preamble.tex"])
        #expect(build.files[0].contents == "P")
        #expect(build.files[1].contents.contains("% sangaku:begin title\n\\title{\\bfseries T}\n% sangaku:end title"))
        #expect(build.files[2].contents.hasSuffix("% sangaku:begin notation\n% n\n% sangaku:end notation\n"))
        #expect(latex.files == [JobFile(path: run + "/p.tex", contents: "\\documentclass{amsart}")])
        #expect(latex.environment["PYTHON"] == nil)
    }

    @Test("A write that fails removes the files it created")
    func installCleansUp() async throws {
        let base = ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path) + "/sangaku-install-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base + "/source", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/folder", withIntermediateDirectories: true)
        try Data("a".utf8).write(to: URL(fileURLWithPath: base + "/source/a.tex"))
        await #expect(throws: ExportError.self) {
            try await ExportFolder.install(["a.tex", "missing.tex"], from: base + "/source", files: [], into: base + "/folder")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: base + "/folder").isEmpty)
    }

    @Test("Why a run failed: its reason, its limit, or its status with the end of what it printed")
    func failedRun() {
        #expect(ExportWording.failedRun("git", .couldNotStart("No."), output: "x") == "git could not run: No.")
        #expect(ExportWording.failedRun("build.sh", .timedOut, output: "") == "build.sh did not finish in time.")
        #expect(ExportWording.failedRun("pdfLaTeX", .exited(1), output: "  ! Emergency stop.\n") == "pdfLaTeX ended with status 1: ! Emergency stop.")
        #expect(ExportWording.failedRun("kit.py new", .signaled(9), output: "") == "kit.py new ended on signal 9.")
        #expect(ExportWording.failedRun("x", .exited(2), output: String(repeating: "a", count: 1000)).count < 450, "only the end")
    }

    @Test("Approval: only the plan shown, by digest")
    func approval() {
        let request = ExportRequest(problemID: UUID(), kind: .leanProject, folder: "/tmp/x")
        let plan = ExportPlan(request: request, files: [ExportFile(path: "a", contents: "1")], regions: nil, folder: .empty)
        let changed = ExportPlan(request: request, files: [ExportFile(path: "a", contents: "2")], regions: nil, folder: .empty)
        let person = PersonID(UUID())
        #expect(throws: Never.self) { try ExportApproval.given(by: person, shown: plan.digest, planned: plan, at: .now) }
        #expect(throws: Approval.Refusal.changedSinceShown) {
            try ExportApproval.given(by: person, shown: plan.digest, planned: changed, at: .now)
        }
    }
}
