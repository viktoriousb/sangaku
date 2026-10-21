import Darwin
import Foundation
import Testing
@testable import sangaku

/// The runner's pure parts: profiles, grants, jobs and output capture.
@Suite("Tools: sandbox profiles and jobs")
struct SandboxProfileTests {
    @Test("Invariant 14: both profiles deny by default; only fetching may use the network")
    func profiles() throws {
        let offline = try #require(SandboxProfile.bundled(.offline))
        let fetch = try #require(SandboxProfile.bundled(.fetch))
        for profile in [offline, fetch] {
            #expect(profile.contains("(deny default)") && profile.contains("(import \"bsd.sb\")"))
            #expect(!profile.contains("/Users"), "nothing in a home folder is granted by the fixed rules")
        }
        #expect(offline.contains("(deny network*)") && !offline.contains("(allow network"))
        #expect(fetch.contains("(allow network*)"))
    }

    @Test("Grants come last, and a path that could break the profile refuses the job")
    func grants() throws {
        let rendered = try SandboxProfile.render(.offline, grants: SandboxGrants(readable: ["/a/b"], writable: ["/c"]),
                                                 source: { _ in "(version 1)(deny default)" })
        #expect(rendered.hasPrefix("(version 1)(deny default)"))
        #expect(rendered.hasSuffix("(allow file-read* (subpath \"/a/b\") (subpath \"/c\"))\n(allow file-write* (subpath \"/c\"))\n"))
        for bad in ["relative/path", "/x\")(allow default", "/x\\y", "/x\ny", "/a/../b", "/a(b)"] {
            #expect(throws: SandboxProfile.Failure.unsafePath) {
                try SandboxProfile.render(.offline, grants: SandboxGrants(readable: [bad]), source: { _ in "" })
            }
        }
        #expect(throws: SandboxProfile.Failure.missingProfile("sandbox-fetch")) {
            try SandboxProfile.render(.fetch, grants: SandboxGrants(), source: { _ in nil })
        }
    }

    @Test("Invariant 14: a job runs exactly the approved text; an approval of other text is refused")
    func approvals() throws {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let me = PersonID(UUID())
        let code = "print(1 + 1)"
        #expect(throws: Approval.Refusal.changedSinceShown) {
            try Approval.given(by: me, shown: TextDigest(of: "print(2)"), stored: code, at: now)
        }
        let approval = try Approval.given(by: me, shown: TextDigest(of: code), stored: code, at: now)
        let job = SandboxJob.compute(approval, cell: UUID(), problem: UUID(), tool: .python,
                                     executable: "/opt/homebrew/bin/python3", toolRoot: nil, runFolder: "/w/run",
                                     limits: .compute)
        #expect(job.files == [JobFile(path: "/w/run/cell.py", contents: code)])
        #expect(job.arguments == ["-I", "-B", "-u", "/w/run/cell.py"] && job.kind == .offline)
        #expect(job.grants.writable == ["/w/run"] && job.grants.readable.isEmpty)
        let gap = SandboxJob.compute(approval, cell: UUID(), problem: UUID(), tool: .gap, executable: "/x/gap",
                                     toolRoot: "/x", runFolder: "/w/run", limits: .compute)
        #expect(gap.files.first?.contents == code + "\nQUIT;\n" && gap.arguments == ["-q", "-b", "/w/run/cell.g"])
    }

    @Test("The environment is built, never inherited")
    func environment() {
        let environment = ToolEnvironment.compute(.python, executable: "/opt/homebrew/bin/python3", runFolder: "/w/run")
        #expect(Set(environment.keys) == ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "PYTHONDONTWRITEBYTECODE",
                                          "PYTHONNOUSERSITE", "PYTHONIOENCODING", "PYTHONHASHSEED"])
        #expect(environment["HOME"] == "/w/run" && environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
    }

    @Test("Output: all of it while it fits, then its start and its end")
    func capture() {
        let capture = OutputCapture(limit: 10)
        capture.append(Data("abc".utf8))
        #expect(capture.result == CappedText(text: "abc"))
        capture.append(Data("defghijklmnopqrstuvwxyz".utf8))
        #expect(capture.result.text == "abcde\n…\nvwxyz" && capture.result.droppedBytes == 16)
        #expect(WaitStatus.end(3 << 8) == .exited(3) && WaitStatus.end(9) == .signaled(9))
    }
}

/// The real runner, with real processes. Each starts in a fresh folder under the system's temporary folder.
@Suite("Tools: running processes", .serialized)
struct ProcessExecutorTests {
    private let executor = ProcessExecutor(runningFolder: nil)
    private let folder: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sangaku-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = ProcessExecutor.canonical(url.path)
    }

    private func run(_ script: String, limits: RunLimits = .compute) async -> RunReport {
        await executor.execute(.testing("/bin/sh", ["-c", script], runFolder: folder + "/run", limits: limits),
                               onOutput: nil)
    }

    @Test("Exit status and both outputs are kept apart")
    func exit() async {
        let report = await run("echo hello; echo oops >&2; exit 3")
        #expect(report.end == .exited(3))
        #expect(report.stdout.text == "hello\n" && report.stderr.text == "oops\n")
        #expect(report.outcome == .exitedNonzero)
    }

    @Test("A timeout kills the program and everything it started")
    func timeout() async throws {
        var limits = RunLimits.compute
        limits.seconds = 1
        limits.killGraceSeconds = 0.5
        let started = Date.now
        let report = await run("echo $$ > group; sleep 60 & sleep 60 & wait", limits: limits)
        #expect(report.end == .timedOut && Date.now.timeIntervalSince(started) < 10)
        let text = try String(contentsOfFile: folder + "/run/group", encoding: .utf8)
        let group = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(killpg(group, 0) == -1 && errno == ESRCH, "no process of the group is left")
    }

    @Test("Stopping the task stops the program")
    func cancel() async {
        let task = Task { await run("sleep 60") }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let report = await task.value
        #expect(report.end == .stopped && report.seconds < 10)
    }

    @Test("A flood of output is drained, kept within the limit, and said to be cut")
    func flood() async {
        var limits = RunLimits.compute
        limits.outputBytes = 1_000
        let report = await run("yes sangaku | head -c 2000000; echo; echo last-line", limits: limits)
        #expect(report.end == .exited(0) && report.stdout.truncated)
        #expect(report.stdout.text.hasPrefix("sangaku\n") && report.stdout.text.hasSuffix("last-line\n"))
    }

    @Test("A program that writes without pause is still stopped at its time limit")
    func endlessFlood() async {
        var limits = RunLimits.compute
        limits.seconds = 1
        limits.outputBytes = 1_000
        limits.killGraceSeconds = 0.5
        let started = Date.now
        let report = await run("yes sangaku-sangaku-sangaku-sangaku", limits: limits)
        #expect(report.end == .timedOut && Date.now.timeIntervalSince(started) < 10, "\(report.end)")
        #expect(report.stdout.truncated)
    }

    @Test("A child that starts a session of its own is still killed with the job",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func escapedChild() async throws {
        var limits = RunLimits.compute
        limits.seconds = 1.5
        limits.killGraceSeconds = 0.5
        let script = #"use POSIX; my $p = fork; if ($p == 0) { POSIX::setsid(); exec "/bin/sleep", "60" } open(my $f, ">", "child"); print $f $p; close $f; sleep 60;"#
        let report = await executor.execute(.testing("/usr/bin/perl", ["-e", script], runFolder: folder + "/run",
                                                     limits: limits), onOutput: nil)
        #expect(report.end == .timedOut, "\(report.end) \(report.stderr.text)")
        let text = try String(contentsOfFile: folder + "/run/child", encoding: .utf8)
        let child = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(getpgid(child) != getpgid(0), "the child had left the job's group")
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(child, 0) == -1 && errno == ESRCH, "and was killed all the same")
    }

    @Test("A program that keeps writing files is stopped at its folder limit")
    func folderLimit() async {
        var limits = RunLimits.compute
        limits.seconds = 30
        limits.folderBytes = 20 << 20
        let report = await run("i=0; while true; do i=$((i+1)); dd if=/dev/zero of=f$i bs=1048576 count=4 2>/dev/null; sleep 0.05; done",
                               limits: limits)
        #expect(report.end == .diskLimit && report.outcome == .diskLimit, "\(report.end)")
    }

    @Test("Quitting kills every running job at once")
    func killAll() async throws {
        let task = Task { await run("sleep 60") }
        try await Task.sleep(for: .milliseconds(300))
        executor.killAll()
        let report = await task.value
        #expect(report.end == .signaled(SIGKILL))
    }

    @Test("A job stopped before it starts runs nothing")
    func cancelledFirst() async {
        let report = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await run("touch ran")
        }.value
        #expect(report.end == .stopped && !FileManager.default.fileExists(atPath: folder + "/run/ran"))
    }

    @Test("A pid file names a running job; the next launch kills what a crash left, and only that")
    func orphans() async throws {
        let running = URL(fileURLWithPath: folder + "/running")
        let withFiles = ProcessExecutor(runningFolder: running)
        let task = Task {
            await withFiles.execute(.testing("/bin/sh", ["-c", "sleep 60"], runFolder: folder + "/run"), onOutput: nil)
        }
        try await waitUntil { ((try? FileManager.default.contentsOfDirectory(atPath: running.path)) ?? []).count == 1 }
        // A file left for a pid now used by another process (this test's) names a different start time.
        let stale = running.appending(path: "\(getpid()).json")
        try JSONColumn.encode(PidFile.Record(pid: getpid(), startTime: 1))!.write(to: stale)
        ProcessExecutor.reapOrphans(in: running)
        let report = await task.value
        #expect(report.end == .signaled(SIGKILL), "the job's group was killed")
        #expect(kill(getpid(), 0) == 0, "the process that reused a pid was left alone")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: running.path)) ?? []).isEmpty)
    }

    @Test("Only the job's own environment and descriptors reach the program")
    func isolation() async {
        let environment = await run("/usr/bin/env")
        let keys = Set(environment.stdout.text.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        #expect(keys.isSubset(of: ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "PWD", "SHLVL", "_"]), "\(keys)")
        // A descriptor the test process holds (as the app holds its store's) is closed in the child.
        let held = Darwin.open("/dev/null", O_RDONLY)
        defer { close(held) }
        let descriptor = await run("if [ -e /dev/fd/\(held) ]; then echo inherited; else echo closed; fi")
        #expect(held > 2 && descriptor.stdout.text == "closed\n")
    }

    @Test("Invariant 14: the sandbox allows the run folder and refuses other writes, home folder reads and the network")
    func sandbox() async throws {
        let outside = folder + "/outside.txt"
        let write = await run("echo in > inside.txt && echo out > '\(outside)'")
        #expect(FileManager.default.fileExists(atPath: folder + "/run/inside.txt"))
        #expect(!FileManager.default.fileExists(atPath: outside) && write.end != .exited(0))

        let home = ProcessExecutor.canonical(NSHomeDirectory())
        let listing = await run("ls '\(home)'")
        #expect(listing.end != .exited(0) && listing.stderr.text.contains("Operation not permitted"))

        let listener = try LoopbackListener()
        let unsandboxed = Process()
        unsandboxed.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        unsandboxed.arguments = ["-z", "-w", "2", "127.0.0.1", "\(listener.port)"]
        try unsandboxed.run()
        unsandboxed.waitUntilExit()
        #expect(unsandboxed.terminationStatus == 0, "the listener is reachable from outside the sandbox")
        let network = await run("/usr/bin/nc -z -w 2 127.0.0.1 \(listener.port)")
        #expect(network.end != .exited(0), "and not from inside it")
    }

    @Test("Invariant 14: the sandbox refuses writes to the shared temporary folders and the home folder, reads of a home file, UDP, and writes to a folder granted only for reading")
    func sandboxEdges() async throws {
        let marker = "sangaku-escape-\(UUID().uuidString)"
        let home = ProcessExecutor.canonical(NSHomeDirectory())
        for target in ["/private/tmp/\(marker)", "/private/var/tmp/\(marker)", "\(home)/\(marker)"] {
            let report = await run("echo out > '\(target)'")
            #expect(report.end != .exited(0) && !FileManager.default.fileExists(atPath: target), "\(target)")
            try? FileManager.default.removeItem(atPath: target)
        }
        let preferences = home + "/Library/Preferences/.GlobalPreferences.plist"
        if FileManager.default.fileExists(atPath: preferences) {
            let read = await run("head -c 1 '\(preferences)'")
            #expect(read.end != .exited(0) && read.stdout.text.isEmpty, "a file in the home folder")
        }

        let readOnly = folder + "/granted"
        try FileManager.default.createDirectory(atPath: readOnly, withIntermediateDirectories: true)
        try Data("kept\n".utf8).write(to: URL(fileURLWithPath: readOnly + "/file"))
        let job = SandboxJob.testing("/bin/sh", ["-c", "cat '\(readOnly)/file' && echo changed > '\(readOnly)/file'"],
                                     runFolder: folder + "/run", readable: [readOnly])
        let granted = await executor.execute(job, onOutput: nil)
        #expect(granted.stdout.text == "kept\n" && granted.end != .exited(0), "read, but not written")
        #expect(try String(contentsOfFile: readOnly + "/file", encoding: .utf8) == "kept\n")

        let udp = try LoopbackDatagrams()
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/bin/sh")
        outside.arguments = ["-c", "echo outside | /usr/bin/nc -u -w 1 127.0.0.1 \(udp.port)"]
        try outside.run()
        outside.waitUntilExit()
        try await Task.sleep(for: .milliseconds(200))
        #expect(udp.received() > 0, "a datagram reaches the listener from outside the sandbox")
        _ = await run("echo inside | /usr/bin/nc -u -w 1 127.0.0.1 \(udp.port)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(udp.received() == 0, "and none from inside it")
    }

    @Test("A program that cannot start is reported as such")
    func missing() async {
        let report = await executor.execute(.testing("/no/such/program", [], runFolder: folder + "/run"), onOutput: nil)
        guard case .couldNotStart = report.end else {
            Issue.record("expected could-not-start, got \(report.end)")
            return
        }
        #expect(report.outcome == .couldNotRun)
    }

    @Test("Python runs in the sandbox, reading its own installation", .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3")))
    func python() async throws {
        let script = folder + "/run/cell.py"
        try FileManager.default.createDirectory(atPath: folder + "/run", withIntermediateDirectories: true)
        try Data("print(sum(range(10)))\n".utf8).write(to: URL(fileURLWithPath: script))
        let report = await executor.execute(.testing("/opt/homebrew/bin/python3", ["-I", "-B", script],
                                                     runFolder: folder + "/run"), onOutput: nil)
        #expect(report.end == .exited(0) && report.stdout.text == "45\n", "\(report.stderr.text)")
    }

    @Test("The memory watchdog stops a program that holds too much", .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3")))
    func memory() async throws {
        var limits = RunLimits.compute
        limits.memoryBytes = 100 << 20
        let script = folder + "/run/hog.py"
        try FileManager.default.createDirectory(atPath: folder + "/run", withIntermediateDirectories: true)
        try Data("import time\nx = bytearray(400_000_000)\nfor i in range(0, len(x), 4096): x[i] = 1\ntime.sleep(30)\n".utf8)
            .write(to: URL(fileURLWithPath: script))
        let report = await executor.execute(.testing("/opt/homebrew/bin/python3", ["-I", script], runFolder: folder + "/run",
                                                     limits: limits), onOutput: nil)
        #expect(report.end == .memoryLimit && report.peakMemoryBytes > 100 << 20)
    }
}

/// A UDP socket on the loopback address that counts the datagrams it has received since it was last asked.
final class LoopbackDatagrams {
    let socket: Int32
    let port: UInt16

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        self.socket = socket
        port = UInt16(bigEndian: address.sin_port)
    }

    func received() -> Int {
        var count = 0
        var buffer = [UInt8](repeating: 0, count: 512)
        while recv(socket, &buffer, buffer.count, 0) > 0 { count += 1 }
        return count
    }

    deinit { close(socket) }
}

/// A TCP listener on the loopback address, for showing the sandbox's network denial.
final class LoopbackListener {
    let socket: Int32
    let port: UInt16

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socket, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        self.socket = socket
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(socket) }
}
