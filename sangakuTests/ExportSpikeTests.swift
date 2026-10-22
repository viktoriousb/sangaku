import Foundation
import Testing
@testable import sangaku

/// The tools an export runs, in the real offline sandbox: the hashtag kit's `kit.py new` and `build.sh`, and a
/// read-only `git status`. Runs only where TeX Live, Homebrew's Python and the kit are installed.
@Suite("Export: the kit, TeX and git in the sandbox", .serialized)
struct ExportSpikeTests {
    nonisolated static let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "hashtag").path
    nonisolated static let python = "/opt/homebrew/bin/python3"
    nonisolated static let texBin = "/Library/TeX/texbin"
    nonisolated static let available = FileManager.default.isExecutableFile(atPath: python)
        && FileManager.default.isExecutableFile(atPath: texBin + "/pdflatex")
        && FileManager.default.fileExists(atPath: kit + "/kit.py")

    private let executor = ProcessExecutor(runningFolder: nil)

    private func folder() -> String {
        ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path) + "/sangaku-spike-\(UUID().uuidString)"
    }

    @Test("kit.py new, then build.sh, pass in the offline sandbox", .enabled(if: available))
    func kitAndBuild() async throws {
        let run = folder()
        defer { try? FileManager.default.removeItem(atPath: run) }
        let project = run + "/project"
        let made = await executor.execute(.testing(Self.python, ["-I", "-B", Self.kit + "/kit.py", "new", project,
                                                                 "--title", "Spike", "--salt", "sangaku-spike"],
                                                   runFolder: run, readable: [Self.kit]), onOutput: nil)
        #expect(made.end == .exited(0), "\(made.stdout.text)\(made.stderr.text)")
        #expect(FileManager.default.fileExists(atPath: project + "/build.sh"))

        let environment = ["PATH": [Self.texBin, "/opt/homebrew/bin", "/usr/bin", "/bin"].joined(separator: ":"),
                           "PYTHON": Self.python, "HOME": run, "TMPDIR": run, "LANG": "en_US.UTF-8",
                           "TEXMFVAR": run + "/texmf-var", "TEXMFCONFIG": run + "/texmf-config"]
        var limits = RunLimits.compute
        limits.seconds = 300
        let built = await executor.execute(.testing("/bin/sh", [project + "/build.sh"], runFolder: run, limits: limits,
                                                    environment: environment), onOutput: nil)
        #expect(built.end == .exited(0), "\(built.stdout.text)\(built.stderr.text)")
        #expect(!built.stdout.text.contains("FAIL") && built.stdout.text.contains("0 errors, 0 undefined references"),
                "\(built.stdout.text)")
        #expect(FileManager.default.fileExists(atPath: project + "/manuscript/main.pdf"))
    }

    @Test("git status reads a repository read-only in the sandbox", .enabled(if: available))
    func gitStatus() async throws {
        let base = folder()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        // A repository with one file never committed: no commit is made in a test.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo, "init", "-q"]
        process.environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "HOME": base]
        try process.run()
        process.waitUntilExit()
        try Data("one\n".utf8).write(to: URL(fileURLWithPath: repo + "/a.tex"))

        let developer = "/Applications/Xcode.app/Contents/Developer"
        let run = base + "/run"
        let status = await executor.execute(.testing(developer + "/usr/bin/git", ["--no-optional-locks", "-C", repo, "status",
                                                                                   "--porcelain=v1", "-z"],
                                                     runFolder: run, readable: [repo, developer],
                                                     environment: ["PATH": "/usr/bin:/bin", "HOME": run, "TMPDIR": run,
                                                                   "GIT_CONFIG_NOSYSTEM": "1",
                                                                   "GIT_CONFIG_GLOBAL": "/dev/null",
                                                                   "DEVELOPER_DIR": developer]),
                                           onOutput: nil)
        #expect(status.end == .exited(0), "\(status.stdout.text)\(status.stderr.text)")
        #expect(status.stdout.text.contains("?? a.tex"), "\(status.stdout.text)")
    }
}
