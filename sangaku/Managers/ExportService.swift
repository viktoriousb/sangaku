import Foundation
import SwiftData

/// How far a running export got.
nonisolated enum ExportPhase: Hashable, Sendable {
    case preparing, checkingFolder, creating, building, compiling, writing

    var words: String {
        switch self {
        case .preparing: "Preparing the export"
        case .checkingFolder: "Asking git whether the folder's files are committed"
        case .creating: "Creating the manuscript with the hashtag kit"
        case .building: "Building with the kit's build.sh"
        case .compiling: "Compiling with pdfLaTeX"
        case .writing: "Writing the folder"
        }
    }
}

/// How the last export of a problem ended, kept in memory for the card and the report.
nonisolated struct ExportOutcome: Hashable, Sendable {
    var kind: ExportKind
    var folder: String
    var error: ExportError?
    var report: BuildReport?
    var written: [String] = []
    /// pdfLaTeX was not set up, so the LaTeX file was written without being compiled.
    var notCompiled = false
    var at: Date

    var succeeded: Bool { error == nil }
}

/// Exports: the LaTeX file, the hashtag manuscript and the Lean project, each from the problem's record through the
/// TeX gate. The only starter of export jobs and the only writer of export folders. An export runs only on a person's
/// click on the plan shown to them (`ExportApproval`), builds in a run folder of its own, and writes the person's folder
/// only when everything passed; it replaces files of an earlier export only when git shows them committed.
@Observable
final class ExportService {
    private(set) var phases: [UUID: ExportPhase] = [:]
    private(set) var outcomes: [UUID: ExportOutcome] = [:]

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let problems: ProblemManager
    @ObservationIgnored let tools: ToolRunner
    @ObservationIgnored let settings: ToolSettings
    @ObservationIgnored let renderer: MathRenderer
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Problems whose export was stopped, or deleted, while it was still being planned.
    @ObservationIgnored private var stopRequested: Set<UUID> = []
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let announce: (String) -> Void

    init(context: ModelContext, problems: ProblemManager, tools: ToolRunner, settings: ToolSettings,
         renderer: MathRenderer, now: @escaping () -> Date = { .now }, announce: @escaping (String) -> Void = { _ in }) {
        self.context = context
        self.problems = problems
        self.tools = tools
        self.settings = settings
        self.renderer = renderer
        self.now = now
        self.announce = announce
    }

    isolated deinit {
        tasks.values.forEach { $0.cancel() }
    }

    func isRunning(problem: UUID) -> Bool { phases[problem] != nil }

    /// The folder this problem was last exported to, for this kind.
    func folder(for problem: UUID, kind: ExportKind) -> String? {
        settings.values.exportFolders?[Self.folderKey(problem, kind)]
    }

    func remember(_ folder: String, for problem: UUID, kind: ExportKind) {
        settings.update { $0.exportFolders = ($0.exportFolders ?? [:]).merging([Self.folderKey(problem, kind): folder]) { $1 } }
    }

    private static func folderKey(_ problem: UUID, _ kind: ExportKind) -> String { problem.uuidString + "/" + kind.rawValue }

    // MARK: Planning

    /// What the export would write, read fresh from the store: the gate refuses before anything is shown.
    func plan(_ request: ExportRequest) async throws(ExportError) -> ExportPlan {
        guard let problem = context.first(Problem.self, stableID: request.problemID) else { throw .noSuchProblem }
        let snapshot = ExportSnapshot.read(problem: problem, people: problems.personIDs())
        let verdicts = FormulaVerdicts.read(snapshot, renderer: renderer)
        let kit = request.kind == .hashtag ? (try? HashtagKit.resolve(settings.values.hashtagKit))?.label : nil
        return try await Self.compose(request, snapshot: snapshot, verdicts: verdicts, kit: kit)
    }

    /// Composes and writes in memory, off the main actor; reads the folder's state.
    @concurrent
    private static func compose(_ request: ExportRequest, snapshot: ExportSnapshot, verdicts: FormulaVerdicts,
                                kit: String?) async throws(ExportError) -> ExportPlan {
        let folder = ExportFolder.state(request.folder, kind: request.kind, problem: request.problemID)
        switch request.kind {
        case .latex:
            let document = try ExportComposer.compose(snapshot, scope: .theoremAndUses, verdicts: verdicts)
            return ExportPlan(request: request, files: [ExportFile(path: latexName(snapshot) + ".tex",
                                                                   contents: LatexWriter.write(document))],
                              regions: nil, folder: folder)
        case .hashtag:
            let document = try ExportComposer.compose(snapshot, scope: .everyStatement, verdicts: verdicts)
            return ExportPlan(request: request, files: HashtagWriter.files(document),
                              regions: HashtagWriter.regions(document), folder: folder, kit: kit)
        case .leanProject:
            do {
                return ExportPlan(request: request, files: try LeanProjectWriter.files(snapshot), regions: nil, folder: folder)
            } catch {
                throw .lean(error)
            }
        }
    }

    /// `normal-sylow-subgroups-g-p-2q`: the file name of the LaTeX export, from the title's letters and digits.
    nonisolated static func latexName(_ snapshot: ExportSnapshot) -> String {
        let words = snapshot.title.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let name = words.joined(separator: "-")
        return name.isEmpty ? "problem-" + LeanNaming.short(snapshot.problemID) : String(name.prefix(60))
    }

    // MARK: Running

    /// Exports what `shown` named: planned again at the click, and refused if anything changed since it was shown.
    /// Returns once the export has started; its outcome is kept in `outcomes`.
    func start(_ request: ExportRequest, shown: TextDigest) async throws(ExportError) {
        let problem = request.problemID
        guard !isRunning(problem: problem) else { throw .running }
        // Set before the first suspension, so a second click cannot start another export meanwhile; Stop and deleting
        // the problem during planning are kept in `stopRequested`.
        phases[problem] = .preparing
        stopRequested.remove(problem)
        do throws(ExportError) {
            let plan = try await plan(request)
            guard stopRequested.remove(problem) == nil else { throw ExportError.stopped }
            guard let title = context.first(Problem.self, stableID: problem)?.title else { throw ExportError.noSuchProblem }
            let approval: ExportApproval
            do throws(Approval.Refusal) {
                approval = try ExportApproval.given(by: problems.me().personID, shown: shown, planned: plan, at: now())
            } catch {
                throw ExportError.changedSinceShown
            }
            if let refusal = plan.folder.refusal { throw ExportError.folder(refusal) }
            let tooling = try tooling(for: request.kind, title: title)
            remember(request.folder, for: problem, kind: request.kind)
            tasks[problem] = Task { [weak self] in
                await self?.run(approval, tooling: tooling)
            }
        } catch {
            phases[problem] = nil
            throw error
        }
    }

    func stop(problem: UUID) {
        if phases[problem] == .preparing { stopRequested.insert(problem) }
        tasks[problem]?.cancel()
        tools.stop(.export(problem: problem))
    }

    /// The problem is being deleted: its export stops, and its outcome is not kept.
    func cancelAll(problemID: UUID) {
        stop(problem: problemID)
        outcomes[problemID] = nil
    }

    /// What an export runs, found at the click.
    private enum Tooling {
        /// The Lean project runs nothing.
        case none
        /// The LaTeX file is compiled when pdfLaTeX is set up: the folder it is in.
        case latex(texBin: String?)
        case manuscript(ExportSetup, KitInfo)
    }

    private func tooling(for kind: ExportKind, title: String) throws(ExportError) -> Tooling {
        let latex = settings.resolution(.pdflatex).path.map { ($0 as NSString).deletingLastPathComponent }
        switch kind {
        case .leanProject:
            return .none
        case .latex:
            return .latex(texBin: latex)
        case .hashtag:
            let kit = try HashtagKit.resolve(settings.values.hashtagKit)
            guard let python = settings.resolution(.python).path else {
                throw .tool("The hashtag kit needs Python. Set it up in Settings.")
            }
            guard let latex else { throw .tool("The manuscript is built with pdfLaTeX. Set it up in Settings.") }
            return .manuscript(ExportSetup(python: python, pythonRoot: settings.locator.installationRoot(of: python),
                                           texBin: latex, kitTitle: HashtagWriter.kitTitle(title)), kit)
        }
    }

    private func run(_ approval: ExportApproval, tooling: Tooling) async {
        let plan = approval.plan
        let problem = plan.request.problemID
        let runFolder = tools.newRunFolder(problem: problem)
        var outcome = ExportOutcome(kind: plan.request.kind, folder: plan.request.folder, at: now())
        // What the export may replace, as it stands now: checked again just before writing.
        let before = await ExportFolder.fingerprint(plan.request.folder, paths: ExportFolder.replacedPaths(plan))
        do throws(ExportError) {
            if plan.folder == .earlierExport { try await checkCommitted(plan, runFolder: runFolder) }
            switch tooling {
            case .none:
                try await install(plan, files: plan.files, staged: [], from: runFolder, before: before, outcome: &outcome)
            case .latex(let texBin):
                try await exportLatex(approval, texBin: texBin, runFolder: runFolder, before: before, outcome: &outcome)
            case .manuscript(let setup, let kit):
                try await exportManuscript(approval, setup: setup, kit: kit, runFolder: runFolder, before: before,
                                           outcome: &outcome)
            }
            announce("\(plan.request.kind.title) exported.")
        } catch {
            outcome.error = error
            if case .build(let report) = error { outcome.report = report }
            announce("\(plan.request.kind.title) not exported.")
        }
        outcome.at = now()
        tools.removeRunFolder(runFolder)
        // A problem deleted meanwhile keeps no outcome.
        outcomes[problem] = context.first(Problem.self, stableID: problem) == nil ? nil : outcome
        phases[problem] = nil
        tasks[problem] = nil
        stopRequested.remove(problem)
    }

    /// Git must show every file the export replaces committed: then nothing a person changed is lost, and git keeps
    /// every earlier version.
    private func checkCommitted(_ plan: ExportPlan, runFolder: String) async throws(ExportError) {
        let problem = plan.request.problemID
        phases[problem] = .checkingFolder
        guard let git = settings.resolution(.git).path else {
            throw .git("Exporting into this folder again needs git, to see that its files are committed. Set up git in Settings.")
        }
        guard let root = ExportFolder.repositoryRoot(of: plan.request.folder), SandboxGrants.isSafe(root) else {
            throw .git("Exporting into this folder again replaces its files, so it must be in a git repository. Run git init there and commit the files, then export again.")
        }
        let paths = ExportFolder.ownedPaths(plan)
        let report = await tools.run(.exportGitStatus(problem: problem, git: git,
                                                      gitRoot: settings.locator.installationRoot(of: git),
                                                      repository: root, folder: plan.request.folder, paths: paths,
                                                      runFolder: runFolder + "/git"))
        try checkStopped()
        guard report.end == .exited(0) else {
            throw .git("git could not read the folder: " + report.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let open = ExportFolder.uncommitted(report.stdout.text)
        guard open.isEmpty else {
            throw .git("Commit or discard the changes to " + Prose.list(open.sorted()) + " first: an export replaces them.")
        }
    }

    private func exportLatex(_ approval: ExportApproval, texBin: String?, runFolder: String,
                             before: [String: String], outcome: inout ExportOutcome) async throws(ExportError) {
        let plan = approval.plan
        guard let texBin else {
            outcome.notCompiled = true
            try await install(plan, files: plan.files, staged: [], from: runFolder, before: before, outcome: &outcome)
            return
        }
        phases[plan.request.problemID] = .compiling
        var report = await tools.run(.exportLatex(approval, texBin: texBin, runFolder: runFolder))
        try checkStopped()
        if report.end == .exited(0) { report = await tools.run(.exportLatex(approval, texBin: texBin, runFolder: runFolder)) }
        try checkStopped()
        let name = ExportService.latexBaseName(plan)
        let log = (try? String(contentsOfFile: runFolder + "/" + name + ".log", encoding: .isoLatin1)) ?? ""
        let errors = log.components(separatedBy: "\n").filter { $0.hasPrefix("! ") }
        guard report.end == .exited(0), errors.isEmpty else { throw .latex(errors.isEmpty ? ["pdfLaTeX did not finish."] : errors) }
        let pdf = name + ".pdf"
        let staged = FileManager.default.fileExists(atPath: runFolder + "/" + pdf) ? [pdf] : []
        try await install(plan, files: plan.files, staged: staged, from: runFolder, before: before, outcome: &outcome)
    }

    /// The LaTeX file's name without `.tex`.
    nonisolated static func latexBaseName(_ plan: ExportPlan) -> String {
        String((plan.files.first?.path ?? "main.tex").dropLast(4))
    }

    private func exportManuscript(_ approval: ExportApproval, setup: ExportSetup, kit: KitInfo, runFolder: String,
                                  before: [String: String], outcome: inout ExportOutcome) async throws(ExportError) {
        let plan = approval.plan
        let problem = plan.request.problemID
        let project = runFolder + "/project"
        let first = plan.folder == .empty
        if first {
            phases[problem] = .creating
            try await HashtagKit.install(kit, to: runFolder + "/kit")
            let made = await tools.run(.exportKit(approval, setup: setup, runFolder: runFolder))
            try checkStopped()
            guard made.end == .exited(0) else {
                throw .kit("kit.py new failed: " + (made.stderr.text + made.stdout.text).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try? FileManager.default.removeItem(atPath: project + "/" + HashtagWriter.kitExample)
        } else {
            try await ExportFolder.stage(plan.request.folder, to: project)
        }
        let bases = (main: (try? String(contentsOfFile: project + "/manuscript/main.tex", encoding: .utf8)) ?? "",
                     preamble: (try? String(contentsOfFile: project + "/manuscript/preamble.tex", encoding: .utf8)) ?? "")
        let oldRegistry = (try? String(contentsOfFile: project + "/manuscript/htag-registry.tex", encoding: .utf8)) ?? ""

        phases[problem] = .building
        let job: SandboxJob
        do throws(HashtagPatchError) {
            job = try .exportBuild(approval, setup: setup, bases: bases, first: first, runFolder: runFolder)
        } catch {
            throw .patch(error)
        }
        let built = await tools.run(job)
        try checkStopped()
        let report = BuildReport.read(built.stdout.text, exitedCleanly: built.end == .exited(0))
        outcome.report = report
        guard report.isPass else { throw .build(report) }
        let newRegistry = (try? String(contentsOfFile: project + "/manuscript/htag-registry.tex", encoding: .utf8)) ?? ""
        guard first || ExportFolder.registryGrows(old: oldRegistry, new: newRegistry) else {
            throw .files("the build changed earlier entries of the tag registry, so nothing was written")
        }
        try await install(plan, files: [], staged: ExportFolder.installSet(project: project, plan: plan, first: first),
                          from: project, before: before, outcome: &outcome)
    }

    /// Writes the export into the person's folder: staged files copied from `source`, then `files`, then the manifest
    /// last. Refused when the folder changed since the export began, so nothing written meanwhile is replaced.
    private func install(_ plan: ExportPlan, files: [ExportFile], staged: [String], from source: String,
                         before: [String: String], outcome: inout ExportOutcome) async throws(ExportError) {
        try checkStopped()
        phases[plan.request.problemID] = .writing
        let folder = plan.request.folder
        let now = await ExportFolder.fingerprint(folder, paths: ExportFolder.replacedPaths(plan))
        guard now == before, ExportFolder.state(folder, kind: plan.request.kind, problem: plan.request.problemID) == plan.folder else {
            throw .folder("The folder changed while the export ran, so nothing was written. Look at the changes, then export again.")
        }
        let manifest = ExportManifest(kind: plan.request.kind, problem: plan.request.problemID)
        let all = files + [ExportFile(path: ExportManifest.fileName, contents: String(decoding: manifest.data, as: UTF8.self))]
        do throws(ExportError) {
            try await ExportFolder.install(staged, from: source, files: all, into: folder)
        } catch {
            guard plan.folder == .earlierExport, case .files(let reason) = error else { throw error }
            throw .files(reason + " Some of the earlier export's files may already be replaced; git holds them as committed.")
        }
        outcome.written = staged + all.map(\.path)
    }

    private func checkStopped() throws(ExportError) {
        if Task.isCancelled { throw .stopped }
    }
}
