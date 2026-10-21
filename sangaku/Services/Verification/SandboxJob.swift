import Foundation

/// A file the runner writes just before the job starts: the approved code, at the path the job reads it from.
nonisolated struct JobFile: Hashable, Sendable {
    let path: String
    let contents: String
}

/// Everything a run needs, decided before it starts: the program, its arguments (never a shell string: in the person's
/// shell `gap` may be an alias), its whole environment, its sandbox and grants, its limits and the files it reads.
/// Made only by the factories below; those that run code a model or a person wrote take an `Approval`, and the file
/// they write holds the approval's text (invariant 14).
nonisolated struct SandboxJob: Hashable, Sendable {
    let key: JobKey
    let problemID: UUID?
    let kind: SandboxKind
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String
    let grants: SandboxGrants
    let limits: RunLimits
    let files: [JobFile]

    private init(key: JobKey, problemID: UUID?, kind: SandboxKind, executable: String, arguments: [String],
                 environment: [String: String], workingDirectory: String, grants: SandboxGrants, limits: RunLimits,
                 files: [JobFile]) {
        self.key = key
        self.problemID = problemID
        self.kind = kind
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.grants = grants
        self.limits = limits
        self.files = files
    }

    /// Compiles a problem's Lean module: the pinned toolchain's own `lean`, never elan's proxy (which would try to
    /// download a toolchain), offline, reading only the toolchain and Mathlib, writing only the run folder, where the
    /// module and its compiled file go.
    static func leanCheck(_ approval: Approval, problem: UUID, setup: LeanCheckSetup, runFolder: String,
                          limits: RunLimits) -> SandboxJob {
        let module = runFolder + "/" + LeanCheckFiles.module
        return SandboxJob(key: .lean(problem: problem), problemID: problem, kind: .offline, executable: setup.lean,
                          arguments: ["--json", "-R", runFolder, "-o", runFolder + "/" + LeanCheckFiles.compiled, module],
                          environment: ToolEnvironment.lean(setup, runFolder: runFolder), workingDirectory: runFolder,
                          grants: SandboxGrants(readable: setup.readable, writable: [runFolder]),
                          limits: limits, files: [JobFile(path: module, contents: approval.text)])
    }

    /// The app's own kernel check of a compiled module (`AxiomCheck.lean`): reads the module as data, replays it through
    /// Lean's kernel on top of its imports and prints each declaration's axioms. It runs no code a model or a person
    /// wrote, so it takes no approval. It reads the compiled module's folder, which is not on Lean's path, and writes
    /// only its own run folder.
    static func leanAxioms(problem: UUID, setup: LeanCheckSetup, compiledModule: String, checker: String,
                           imports: [String], declarations: [String], runFolder: String, limits: RunLimits) -> SandboxJob {
        let script = runFolder + "/" + LeanCheckFiles.checker
        return SandboxJob(key: .lean(problem: problem), problemID: problem, kind: .offline, executable: setup.lean,
                          arguments: ["--run", script, compiledModule, imports.joined(separator: ",")] + declarations,
                          environment: ToolEnvironment.lean(setup, runFolder: runFolder), workingDirectory: runFolder,
                          grants: SandboxGrants(readable: setup.readable + [(compiledModule as NSString).deletingLastPathComponent],
                                                writable: [runFolder]),
                          limits: limits, files: [JobFile(path: script, contents: checker)])
    }

    /// The last step of fetching Mathlib: an app-written module that only imports it, compiled in the same offline
    /// sandbox a check uses.
    static func leanProbe(setup: LeanCheckSetup, runFolder: String, limits: RunLimits) -> SandboxJob {
        let module = runFolder + "/Probe.lean"
        return SandboxJob(key: .fetch, problemID: nil, kind: .offline, executable: setup.lean,
                          arguments: ["--json", module], environment: ToolEnvironment.lean(setup, runFolder: runFolder),
                          workingDirectory: runFolder, grants: SandboxGrants(readable: setup.readable, writable: [runFolder]),
                          limits: limits,
                          files: [JobFile(path: module, contents: LeanModulePlan.imports.map { "import " + $0 + "\n" }.joined())])
    }

    /// Runs a computation cell's approved code with its tool, offline, reading and writing only its run folder.
    static func compute(_ approval: Approval, cell: UUID, problem: UUID, tool: EvidenceTool, executable: String,
                        toolRoot: String?, runFolder: String, limits: RunLimits) -> SandboxJob {
        let script = runFolder + "/" + ComputeCommands.scriptName(tool)
        return SandboxJob(key: .cell(cell), problemID: problem, kind: .offline, executable: executable,
                          arguments: ComputeCommands.arguments(tool, script: script),
                          environment: ToolEnvironment.compute(ToolID(tool), executable: executable, runFolder: runFolder),
                          workingDirectory: runFolder,
                          grants: SandboxGrants(readable: toolRoot.map { [$0] } ?? [], writable: [runFolder]),
                          limits: limits, files: [JobFile(path: script, contents: ComputeCommands.script(tool, approval.text))])
    }

    /// A step of fetching Mathlib. Runs only the toolchain's programs on arguments the app chose, with the network.
    /// Mathlib's compiled files are cached inside the workspace, so nothing else in the home folder is written.
    static func fetch(executable: String, arguments: [String], setup: LeanFetchSetup, limits: RunLimits) -> SandboxJob {
        SandboxJob(key: .fetch, problemID: nil, kind: .fetch, executable: executable, arguments: arguments,
                   environment: ToolEnvironment.fetch(setup), workingDirectory: setup.workspace,
                   grants: SandboxGrants(readable: [], writable: [setup.workspace, setup.elanHome]),
                   limits: limits, files: [])
    }

    /// Asks a tool for its version, offline.
    static func probe(_ tool: ToolID, executable: String, arguments: [String], toolRoot: String?,
                      runFolder: String) -> SandboxJob {
        SandboxJob(key: .probe(UUID()), problemID: nil, kind: .offline, executable: executable, arguments: arguments,
                   environment: ToolEnvironment.compute(tool, executable: executable, runFolder: runFolder),
                   workingDirectory: runFolder,
                   grants: SandboxGrants(readable: toolRoot.map { [$0] } ?? [], writable: [runFolder]),
                   limits: .probe, files: [])
    }

    #if DEBUG
    /// For the runner's own tests: any program, in the offline sandbox, with a run folder.
    static func testing(_ executable: String, _ arguments: [String], runFolder: String, readable: [String] = [],
                        limits: RunLimits = .compute, kind: SandboxKind = .offline, key: JobKey = .probe(UUID()),
                        problem: UUID? = nil) -> SandboxJob {
        SandboxJob(key: key, problemID: problem, kind: kind, executable: executable, arguments: arguments,
                   environment: ToolEnvironment.base(executable: executable, runFolder: runFolder),
                   workingDirectory: runFolder, grants: SandboxGrants(readable: readable, writable: [runFolder]),
                   limits: limits, files: [])
    }
    #endif
}

/// What a Lean check runs and reads: the toolchain's own `lean`, and Mathlib's compiled files on Lean's path.
nonisolated struct LeanCheckSetup: Hashable, Sendable {
    var toolchainRoot: String
    var lean: String
    var leanPath: [String]

    /// Everything a check may read besides its run folder.
    var readable: [String] { [toolchainRoot] + leanPath }
}

/// The files of a check in its run folder.
nonisolated enum LeanCheckFiles {
    static let module = "SangakuCheck.lean"
    static let compiled = "SangakuCheck.olean"
    static let checker = "AxiomCheck.lean"

    /// The app's kernel check, bundled as `AxiomCheck.lean`; nil if the app was built without it.
    static var checkerSource: String? {
        Bundle.main.url(forResource: "AxiomCheck", withExtension: "lean")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// Where fetching Mathlib may write: the workspace (with its cache folder) and elan's folder.
nonisolated struct LeanFetchSetup: Hashable, Sendable {
    var workspace: String
    var elanHome: String
    var cacheHome: String
    var home: String
    var toolchainBin: String?
}

/// The whole environment of a job: nothing is inherited from the app, so no key, path or setting leaks into a tool.
nonisolated enum ToolEnvironment {
    static func base(executable: String, runFolder: String) -> [String: String] {
        let directory = (executable as NSString).deletingLastPathComponent
        return ["PATH": [directory, "/usr/bin", "/bin"].joined(separator: ":"), "HOME": runFolder, "TMPDIR": runFolder,
                "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
    }

    static func compute(_ tool: ToolID, executable: String, runFolder: String) -> [String: String] {
        var environment = base(executable: executable, runFolder: runFolder)
        if tool == .python {
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["PYTHONNOUSERSITE"] = "1"
            environment["PYTHONIOENCODING"] = "utf-8"
            environment["PYTHONHASHSEED"] = "0"
        }
        return environment
    }

    static func lean(_ setup: LeanCheckSetup, runFolder: String) -> [String: String] {
        var environment = base(executable: setup.lean, runFolder: runFolder)
        environment["LEAN_PATH"] = setup.leanPath.joined(separator: ":")
        return environment
    }

    static func fetch(_ setup: LeanFetchSetup) -> [String: String] {
        let path = ([setup.toolchainBin, setup.elanHome + "/bin"].compactMap { $0 } + ["/usr/bin", "/bin"])
            .joined(separator: ":")
        return ["PATH": path, "HOME": setup.home, "ELAN_HOME": setup.elanHome, "XDG_CACHE_HOME": setup.cacheHome,
                "MATHLIB_CACHE_DIR": setup.cacheHome + "/mathlib", "LANG": "en_US.UTF-8",
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]
    }
}

/// How each computation tool runs a script: a file in the run folder, with arguments, never through a shell.
nonisolated enum ComputeCommands {
    static func scriptName(_ tool: EvidenceTool) -> String {
        switch tool {
        case .python: "cell.py"
        case .gap: "cell.g"
        case .sage: "cell.sage"
        }
    }

    static func arguments(_ tool: EvidenceTool, script: String) -> [String] {
        switch tool {
        // Isolated mode: no user site, no environment variables, no current directory on the path.
        case .python: ["-I", "-B", "-u", script]
        // Quiet, no banner, and the script ends with QUIT so GAP never waits for input.
        case .gap: ["-q", "-b", script]
        case .sage: [script]
        }
    }

    /// The file as written: the approved code, with `QUIT;` after a GAP script.
    static func script(_ tool: EvidenceTool, _ code: String) -> String {
        tool == .gap ? code + "\nQUIT;\n" : code
    }
}
