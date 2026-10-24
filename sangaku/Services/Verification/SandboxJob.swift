import Foundation

/// A file the runner writes just before the job starts: the approved code, at the path the job reads it from.
nonisolated struct JobFile: Hashable, Sendable {
    let path: String
    let contents: String
}

/// Everything a run needs, decided before it starts: the program, its arguments (never a shell string: in the person's
/// shell `gap` may be an alias), its whole environment, its sandbox and grants, its limits and the files it reads.
/// Made only by the factories below; those that run code a model or a person wrote take an `Approval`, and the file
/// they write holds the approval's text (invariant 14). The export's jobs that compile TeX take an `ExportApproval`,
/// and write only the files of the plan it holds.
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

    /// `kit.py new` from the copy of the hashtag kit in the run folder, making the project there: the person's kit
    /// folder is never granted, and the title it gets is the neutral one from the approved plan.
    static func exportKit(_ approval: ExportApproval, setup: ExportSetup, runFolder: String) -> SandboxJob {
        let problem = approval.plan.request.problemID
        return SandboxJob(key: .export(problem: problem), problemID: problem, kind: .offline, executable: setup.python,
                          arguments: ["-I", "-B", runFolder + "/kit/kit.py", "new", runFolder + "/project",
                                      "--title", setup.kitTitle, "--salt", HashtagWriter.salt(problem)],
                          environment: ToolEnvironment.export(texBin: setup.texBin, python: setup.python, runFolder: runFolder), workingDirectory: runFolder,
                          grants: SandboxGrants(readable: setup.readable, writable: [runFolder]), limits: .kit, files: [])
    }

    /// The kit's `build.sh` on the staged project, after writing the approved files and regions into it. The regions
    /// go into `main.tex` and `preamble.tex` as the kit made them (`first`) or as the earlier export left them.
    static func exportBuild(_ approval: ExportApproval, setup: ExportSetup, bases: (main: String, preamble: String),
                            first: Bool, runFolder: String) throws(HashtagPatchError) -> SandboxJob {
        let problem = approval.plan.request.problemID
        let project = runFolder + "/project/"
        var files = approval.plan.files.map { JobFile(path: project + $0.path, contents: $0.contents) }
        if let regions = approval.plan.regions {
            let main = first ? try HashtagWriter.firstMain(bases.main, regions: regions)
                : try HashtagWriter.update(bases.main, file: "manuscript/main.tex",
                                           regions: [("title", regions.title), ("chapters", regions.chapters)])
            let preamble = first ? HashtagWriter.firstPreamble(bases.preamble, regions: regions)
                : try HashtagWriter.update(bases.preamble, file: "manuscript/preamble.tex", regions: [("notation", regions.notation)])
            files += [JobFile(path: project + "manuscript/main.tex", contents: main),
                      JobFile(path: project + "manuscript/preamble.tex", contents: preamble)]
        }
        return SandboxJob(key: .export(problem: problem), problemID: problem, kind: .offline, executable: "/bin/sh",
                          arguments: [project + "build.sh"], environment: ToolEnvironment.export(texBin: setup.texBin, python: setup.python, runFolder: runFolder),
                          workingDirectory: runFolder, grants: SandboxGrants(readable: setup.readable, writable: [runFolder]),
                          limits: .export, files: files)
    }

    /// One pdfLaTeX pass over the approved LaTeX file, to show that it compiles on its own.
    static func exportLatex(_ approval: ExportApproval, texBin: String, runFolder: String) -> SandboxJob {
        let problem = approval.plan.request.problemID
        let file = approval.plan.files.first { $0.path.hasSuffix(".tex") }
        return SandboxJob(key: .export(problem: problem), problemID: problem, kind: .offline,
                          executable: texBin + "/pdflatex",
                          arguments: ["-interaction=nonstopmode", "-no-shell-escape", file?.path ?? "main.tex"],
                          environment: ToolEnvironment.export(texBin: texBin, python: nil, runFolder: runFolder),
                          workingDirectory: runFolder, grants: SandboxGrants(readable: [], writable: [runFolder]), limits: .export,
                          files: file.map { [JobFile(path: runFolder + "/" + $0.path, contents: $0.contents)] } ?? [])
    }

    /// git's status of the export's files in the person's folder, read-only: no lock, no index refresh written. It
    /// reads the repository the folder is in, which may hold it a few levels down.
    static func exportGitStatus(problem: UUID, git: ExportGit, repository: String, folder: String, paths: [String],
                                runFolder: String) -> SandboxJob {
        SandboxJob(key: .export(problem: problem), problemID: problem, kind: .offline, executable: git.program,
                   arguments: ["--no-optional-locks", "-C", folder, "status", "--porcelain=v1", "-z",
                               "--ignored=matching", "--untracked-files=all", "--"] + paths,
                   environment: ToolEnvironment.git(git, runFolder: runFolder), workingDirectory: runFolder,
                   grants: SandboxGrants(readable: [repository] + git.readable, writable: [runFolder]),
                   limits: .kit, files: [])
    }

    /// `git init` in an export's folder that is in no repository yet: it writes only the folder's new `.git`.
    static func exportGitInit(problem: UUID, git: ExportGit, folder: String, runFolder: String) -> SandboxJob {
        SandboxJob(key: .export(problem: problem), problemID: problem, kind: .offline, executable: git.program,
                   arguments: ["-C", folder, "init", "-q", "-b", "main"],
                   environment: ToolEnvironment.git(git, runFolder: runFolder), workingDirectory: runFolder,
                   grants: SandboxGrants(readable: [folder] + git.readable, writable: [runFolder, folder + "/.git"]),
                   limits: .git, files: [])
    }

    /// `git add` of exactly the files an export wrote, writing only the repository's `.git`.
    static func exportGitAdd(problem: UUID, git: ExportGit, repository: String, folder: String, paths: [String],
                             runFolder: String) -> SandboxJob {
        SandboxJob(key: .export(problem: problem), problemID: problem, kind: .offline, executable: git.program,
                   arguments: ["-C", folder, "add", "--"] + paths,
                   environment: ToolEnvironment.git(git, runFolder: runFolder), workingDirectory: runFolder,
                   grants: SandboxGrants(readable: [repository] + git.readable, writable: [runFolder, repository + "/.git"]),
                   limits: .git, files: [])
    }

    /// `git commit --only` of exactly the files an export wrote, as the person (`ExportGit.identity`): anything else
    /// the person had staged stays staged and out of the commit.
    static func exportGitCommit(problem: UUID, git: ExportGit, repository: String, folder: String, paths: [String],
                                message: String, runFolder: String) -> SandboxJob {
        var environment = ToolEnvironment.git(git, runFolder: runFolder)
        for role in ["AUTHOR", "COMMITTER"] {
            environment["GIT_\(role)_NAME"] = git.identity.name
            environment["GIT_\(role)_EMAIL"] = git.identity.email
        }
        return SandboxJob(key: .export(problem: problem), problemID: problem, kind: .offline, executable: git.program,
                          arguments: ["-C", folder, "commit", "-q", "-m", message, "--only", "--"] + paths,
                          environment: environment, workingDirectory: runFolder,
                          grants: SandboxGrants(readable: [repository] + git.readable,
                                                writable: [runFolder, repository + "/.git"]),
                          limits: .git, files: [])
    }

    #if DEBUG
    /// For the runner's own tests: any program, in the offline sandbox, with a run folder.
    static func testing(_ executable: String, _ arguments: [String], runFolder: String, readable: [String] = [],
                        limits: RunLimits = .compute, kind: SandboxKind = .offline, key: JobKey = .probe(UUID()),
                        problem: UUID? = nil, environment: [String: String]? = nil) -> SandboxJob {
        SandboxJob(key: key, problemID: problem, kind: kind, executable: executable, arguments: arguments,
                   environment: environment ?? ToolEnvironment.base(executable: executable, runFolder: runFolder),
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
/// The tools the manuscript's export runs, found before it starts.
nonisolated struct ExportSetup: Hashable, Sendable {
    var python: String
    var pythonRoot: String?
    /// The folder `pdflatex` is in; TeX finds the rest of its installation from there.
    var texBin: String
    /// The title `kit.py new` gets.
    var kitTitle: String = "Exported problem"

    var readable: [String] { pythonRoot.map { [$0] } ?? [] }
}

/// git as an export runs it: the program, its installation (readable), and the person whose commits it makes.
nonisolated struct ExportGit: Hashable, Sendable {
    var program: String
    var root: String?
    var identity: GitIdentity

    var readable: [String] { root.map { [$0] } ?? [] }
}

/// The whole environment of each kind of job: nothing of the app's own environment is passed on.
nonisolated enum ToolEnvironment {
    /// git with no system or global configuration (so no hooks, aliases or signing from them), no prompts and no
    /// optional locks; Xcode's git finds its developer folder.
    static func git(_ git: ExportGit, runFolder: String) -> [String: String] {
        var environment = base(executable: git.program, runFolder: runFolder)
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if let root = git.root, root.hasSuffix("/usr") { environment["DEVELOPER_DIR"] = String(root.dropLast(4)) }
        return environment
    }

    /// TeX writes only into the run folder and runs no shell commands; Python, when there is one, reads no user site.
    static func export(texBin: String, python: String?, runFolder: String) -> [String: String] {
        let pythonBin = python.map { ($0 as NSString).deletingLastPathComponent }
        var environment = ["PATH": ([texBin] + (pythonBin.map { [$0] } ?? []) + ["/usr/bin", "/bin"]).joined(separator: ":"),
                           "HOME": runFolder, "TMPDIR": runFolder, "LANG": "en_US.UTF-8",
                           "TEXMFVAR": runFolder + "/texmf-var", "TEXMFCONFIG": runFolder + "/texmf-config",
                           "TEXMFHOME": runFolder + "/texmf-home", "shell_escape": "f", "openout_any": "p",
                           "openin_any": "p", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"]
        environment["PYTHON"] = python
        return environment
    }

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
