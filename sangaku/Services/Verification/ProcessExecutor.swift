import Darwin
import Foundation
import Synchronization

/// The one place the app starts a process. Every job runs as `/usr/bin/sandbox-exec -p <profile> <program> <args>`,
/// with the job's environment only, standard input from /dev/null, default signal handling and no other descriptor of
/// the app inherited. The program gets a session of its own, and the watchdog also keeps track of descendants that
/// start sessions of their own, so a timeout, a memory or folder limit or Stop kills the whole tree: first politely,
/// then for good. A pid file per running job lets the next launch kill what a crash left behind.
nonisolated final class ProcessExecutor: ToolExecuting {
    private let profiles: @Sendable (SandboxKind) -> String?
    private let runningFolder: URL?
    private let running = Mutex<Set<pid_t>>([])

    /// `runningFolder` holds the pid files; nil keeps none (tests).
    init(runningFolder: URL?, profiles: @escaping @Sendable (SandboxKind) -> String? = SandboxProfile.bundled) {
        self.runningFolder = runningFolder
        self.profiles = profiles
    }

    func killAll() {
        for pid in running.withLock({ $0 }) {
            killpg(pid, SIGKILL)
            ProcessGroup.descendants(of: pid).forEach { kill($0, SIGKILL) }
        }
    }

    @concurrent func execute(_ job: SandboxJob, onOutput: (@Sendable (String) -> Void)?) async -> RunReport {
        let start = Date.now
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            return .couldNotStart("The macOS sandbox (sandbox-exec) is not available, so nothing is run.", at: start)
        }
        guard FileManager.default.isExecutableFile(atPath: job.executable) else {
            return .couldNotStart("\(job.executable) is not a program that can be run.", at: start)
        }
        do {
            try FileManager.default.createDirectory(atPath: job.workingDirectory, withIntermediateDirectories: true)
            for writable in job.grants.writable {
                try FileManager.default.createDirectory(atPath: writable, withIntermediateDirectories: true)
            }
            for file in job.files {
                try Data(file.contents.utf8).write(to: URL(fileURLWithPath: file.path), options: .atomic)
            }
        } catch {
            return .couldNotStart("The files for the run could not be written: \(error.localizedDescription)", at: start)
        }
        // The sandbox matches real paths only: /var is /private/var.
        let grants = SandboxGrants(readable: job.grants.readable.map(Self.canonical),
                                   writable: job.grants.writable.map(Self.canonical))
        let profile: String
        do throws(SandboxProfile.Failure) {
            profile = try SandboxProfile.render(job.kind, grants: grants, source: profiles)
        } catch {
            return .couldNotStart(error.message, at: start)
        }

        // Stopped before it started: nothing runs.
        guard !Task.isCancelled else {
            return RunReport(end: .stopped, stdout: CappedText(text: ""), stderr: CappedText(text: ""), startedAt: start,
                             seconds: 0)
        }
        let process: SpawnedProcess
        switch SpawnedProcess.spawn(argv: ["/usr/bin/sandbox-exec", "-p", profile, job.executable] + job.arguments,
                                    environment: job.environment, directory: job.workingDirectory) {
        case .success(let spawned): process = spawned
        case .failure(let reason): return .couldNotStart(reason.message, at: start)
        }
        running.withLock { _ = $0.insert(process.pid) }
        let pidFile = PidFile.write(process.pid, in: runningFolder)
        defer {
            running.withLock { _ = $0.remove(process.pid) }
            pidFile.map { try? FileManager.default.removeItem(at: $0) }
        }

        let stdout = OutputCapture(limit: job.limits.outputBytes)
        let stderr = OutputCapture(limit: job.limits.outputBytes)
        let watch = Watch(pid: process.pid, limits: job.limits, folders: grants.writable)
        let status = await withTaskCancellationHandler {
            await process.run(stdout: stdout, stderr: stderr, onOutput: onOutput, watch: watch)
        } onCancel: {
            watch.stop(.stopped)
        }
        // A run whose end could not be read says nothing.
        let end: RunEnd = watch.reason ?? status.map(WaitStatus.end)
            ?? .couldNotStart("The program's end could not be read, so nothing is recorded.")
        return RunReport(end: end, stdout: stdout.result, stderr: stderr.result, startedAt: start,
                         seconds: Date.now.timeIntervalSince(start), peakMemoryBytes: watch.peak)
    }

    /// The path with every symbolic link resolved, or as given when it does not exist.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Kills the process groups that pid files from an earlier run of the app still name, if the process is the same one
    /// (same start time), then removes the files.
    static func reapOrphans(in folder: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "json" {
            if let record = JSONColumn.decode(PidFile.Record.self, from: try? Data(contentsOf: file)),
               PidFile.startTime(of: record.pid) == record.startTime {
                killpg(record.pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// The wait status as `waitpid` gives it (the C macros are not visible from Swift): low 7 bits the terminating signal, 0
/// for a normal exit, whose code is in the next byte.
nonisolated enum WaitStatus {
    static func end(_ status: Int32) -> RunEnd {
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }
}

/// The reason a job was ended from outside, decided once (a Stop after a timeout stays a timeout) and never after the
/// program ended on its own, and the watchdog that enforces the limits.
nonisolated final class Watch: Sendable {
    private struct State {
        var reason: RunEnd?
        var finished = false
        var peak: UInt64 = 0
        var ticks = 0
        /// Descendants seen outside the group (a child that started a session of its own), with their start times.
        var escaped: [pid_t: UInt64] = [:]
    }

    let pid: pid_t
    let limits: RunLimits
    /// The folders the job may write, measured against `limits.folderBytes`.
    let folders: [String]
    private let state = Mutex(State())

    init(pid: pid_t, limits: RunLimits, folders: [String] = []) {
        self.pid = pid
        self.limits = limits
        self.folders = folders
    }

    var reason: RunEnd? { state.withLock { $0.reason } }
    var peak: UInt64 { state.withLock { $0.peak } }

    /// Ends the job: SIGTERM to its group and to every descendant seen outside it, SIGKILL after the grace period.
    func stop(_ reason: RunEnd) {
        let first = state.withLock { state -> Bool in
            guard state.reason == nil, !state.finished else { return false }
            state.reason = reason
            return true
        }
        guard first else { return }
        send(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + limits.killGraceSeconds) { [self] in send(SIGKILL) }
    }

    /// The program ended on its own: nothing after this changes how the run ended.
    func finish() {
        state.withLock { $0.finished = true }
    }

    /// Kills whatever of the job is left: its group and the descendants that left it, if they are the same processes.
    func killRemaining() {
        send(SIGKILL)
    }

    private func send(_ signal: Int32) {
        killpg(pid, signal)
        let escaped = state.withLock { $0.escaped }
        for (descendant, start) in escaped where PidFile.startTime(of: descendant) == start { kill(descendant, signal) }
    }

    /// One look at the clock, the memory of the group and its escaped descendants, and, every second, the folders.
    func tick(elapsed: Double) {
        if elapsed > limits.seconds { stop(.timedOut) }
        let outside = ProcessGroup.descendants(of: pid).filter { getpgid($0) != pid }
        let starts = outside.compactMap { pid in PidFile.startTime(of: pid).map { (pid, $0) } }
        let (escaped, ticks) = state.withLock { state -> ([pid_t], Int) in
            for (pid, start) in starts { state.escaped[pid] = start }
            state.ticks += 1
            return (Array(state.escaped.keys), state.ticks)
        }
        let footprint = ProcessGroup.footprint(of: ProcessGroup.members(of: pid) + escaped)
        state.withLock { $0.peak = max($0.peak, footprint) }
        if footprint > limits.memoryBytes { stop(.memoryLimit) }
        if let limit = limits.folderBytes, ticks % 5 == 0,
           FolderSize.exceeds(limit, folders: folders) { stop(.diskLimit) }
    }
}

/// How much a run's folders hold, counted until a limit is passed.
nonisolated enum FolderSize {
    static func exceeds(_ limit: UInt64, folders: [String]) -> Bool {
        var total: UInt64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        for folder in folders {
            guard let items = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys)
            else { continue }
            for case let item as URL in items {
                guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                total += UInt64(values.totalFileAllocatedSize ?? 0)
                if total > limit { return true }
            }
        }
        return false
    }
}

/// A started process: its pid (also its process group and session) and the read ends of its two pipes.
nonisolated struct SpawnedProcess: Sendable {
    nonisolated struct Failure: Error {
        let message: String
    }

    let pid: pid_t
    let stdoutFD: Int32
    let stderrFD: Int32

    static func spawn(argv: [String], environment: [String: String], directory: String) -> Result<SpawnedProcess, Failure> {
        var out: [Int32] = [0, 0]
        var err: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&err) == 0 else { return .failure(Failure(message: "No pipe for the output.")) }

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        posix_spawn_file_actions_addchdir(&actions, directory)

        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session, no descriptor but the three above, no blocked signal and every signal at its default.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let arguments = argv.map { strdup($0) } + [nil]
        let variables = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, argv[0], &actions, &attributes, arguments, variables)
        close(out[1])
        close(err[1])
        guard result == 0 else {
            close(out[0])
            close(err[0])
            return .failure(Failure(message: "The program could not be started: \(String(cString: strerror(result)))."))
        }
        return .success(SpawnedProcess(pid: pid, stdoutFD: out[0], stderrFD: err[0]))
    }

    /// Reads both pipes until they close, watches the limits, and waits for the exit. Returns the raw wait status, or
    /// nil if it could not be read. The watchdog has a queue of its own, so no amount of output can delay it.
    func run(stdout: OutputCapture, stderr: OutputCapture, onOutput: (@Sendable (String) -> Void)?,
             watch: Watch) async -> Int32? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "local.sangaku.tool.\(pid)")
            let readers = DispatchGroup()
            let sources = [(stdoutFD, stdout, onOutput), (stderrFD, stderr, nil)].map { fd, capture, forward in
                PipeReader.start(fd: fd, capture: capture, forward: forward, queue: queue, group: readers)
            }
            let started = Date.now
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "local.sangaku.watch.\(pid)"))
            timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
            timer.setEventHandler { watch.tick(elapsed: Date.now.timeIntervalSince(started)) }
            timer.resume()
            let pid = pid
            DispatchQueue.global().async {
                var status: Int32 = 0
                var result = waitpid(pid, &status, 0)
                while result == -1 && errno == EINTR { result = waitpid(pid, &status, 0) }
                watch.finish()
                timer.cancel()
                // Whatever the program left running goes with it, so the pipes close.
                watch.killRemaining()
                if readers.wait(timeout: .now() + 2) == .timedOut {
                    // A descendant left the group and holds a pipe open: stop reading it.
                    sources.forEach { $0.cancel() }
                    readers.wait()
                }
                continuation.resume(returning: result == pid ? status : nil)
            }
        }
    }
}

/// Drains one pipe into a capture without ever blocking the program on a full pipe. Each event reads at most a
/// megabyte, so a program that writes without pause cannot hold the reading queue.
nonisolated enum PipeReader {
    static func start(fd: Int32, capture: OutputCapture, forward: (@Sendable (String) -> Void)?, queue: DispatchQueue,
                      group: DispatchGroup) -> DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        group.enter()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            for _ in 0..<16 {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    let data = Data(buffer[0..<count])
                    capture.append(data)
                    forward?(String(decoding: data, as: UTF8.self))
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    source.cancel()
                    return
                } else if errno == EAGAIN {
                    return
                }
            }
            // More may be waiting; the source fires again.
        }
        source.setCancelHandler {
            close(fd)
            group.leave()
        }
        source.resume()
        return source
    }
}

/// The processes of a process group, a process's descendants, and the memory they hold together.
nonisolated enum ProcessGroup {
    static func members(of group: pid_t) -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 16)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// Every process descending from `pid`, by parent, while the chain is intact.
    static func descendants(of pid: pid_t) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for child in pids.prefix(Int(found)) where child > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            children[pid_t(info.pbi_ppid), default: []].append(child)
        }
        var result: [pid_t] = []
        var queue = children[pid] ?? []
        while let next = queue.popLast() {
            result.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return result
    }

    /// The physical footprint of these processes together, in bytes.
    static func footprint(of pids: [pid_t]) -> UInt64 {
        Set(pids).reduce(0) { total, pid in
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return result == 0 ? total + info.ri_phys_footprint : total
        }
    }
}

/// A file per running job, naming its process and when it started, so a later launch can tell it from a new process
/// that reused the pid.
nonisolated enum PidFile {
    nonisolated struct Record: Codable, Hashable, Sendable {
        var pid: pid_t
        var startTime: UInt64
    }

    static func write(_ pid: pid_t, in folder: URL?) -> URL? {
        guard let folder, let start = startTime(of: pid) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(pid).json")
        guard let data = JSONColumn.encode(Record(pid: pid, startTime: start)) else { return nil }
        return (try? data.write(to: url)) == nil ? nil : url
    }

    static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}
