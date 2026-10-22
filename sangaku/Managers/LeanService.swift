import Foundation
import SwiftData

/// What a Check runs as a statement's code.
nonisolated indirect enum LeanCandidate: Hashable, Sendable {
    /// A formalizer's draft, as stored on its message.
    case draft(messageID: UUID)
    /// Code a person wrote, or edited from `basedOn`, in the sheet that checks it. Unchanged from its base, it keeps
    /// the base's author.
    case typed(LeanSource, basedOn: LeanCandidate? = nil)
    /// The statement's checked code, checked again.
    case current
}

/// Fetching Mathlib, as far as it got.
nonisolated struct FetchProgress: Hashable, Sendable {
    var step = 0
    var steps = 0
    var title = ""
    /// The latest line of output.
    var line = ""
    var failure: String?
    var isRunning = false
}

/// Lean in the app: the shared workspace and fetching Mathlib into it, checking a problem's module, and a person's
/// fidelity review of a checked Lean statement. The only writer of `LeanResult` and `FidelityReview` outside the
/// fixture. A check runs only on a person's click on the module shown to them (invariant 14). Lean compiles the module,
/// then the app's own kernel check replays the compiled module and reports each statement's axioms, so a statement's
/// code cannot speak for its own result (invariant 12). A fidelity review is only ever the person's using the app
/// (invariant 1).
@Observable
final class LeanService {
    private(set) var workspace: LeanWorkspaceState = .noFolder
    private(set) var fetch = FetchProgress()
    /// Why the last check of a statement ran but recorded nothing, until a check of it records.
    private(set) var lastFailure: [UUID: String] = [:]

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let saves: SaveScheduler
    @ObservationIgnored let problems: ProblemManager
    @ObservationIgnored let tools: ToolRunner
    @ObservationIgnored let settings: ToolSettings
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var checks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let now: () -> Date
    /// elan's folder, where the pinned toolchain is installed.
    @ObservationIgnored private let elanHome: String
    /// Says how a check or a fetch ended, for VoiceOver: it ends long after the click.
    @ObservationIgnored private let announce: (String) -> Void

    init(context: ModelContext, saves: SaveScheduler, problems: ProblemManager, tools: ToolRunner,
         settings: ToolSettings, elanHome: String = LeanWorkspace.defaultElanHome, now: @escaping () -> Date = { .now },
         announce: @escaping (String) -> Void = { _ in }) {
        self.context = context
        self.saves = saves
        self.problems = problems
        self.tools = tools
        self.settings = settings
        self.elanHome = elanHome
        self.now = now
        self.announce = announce
    }

    isolated deinit {
        fetchTask?.cancel()
        checks.values.forEach { $0.cancel() }
    }

    var currentWorkspace: LeanWorkspace? {
        settings.values.leanWorkspace.map { LeanWorkspace(root: $0, elanHome: elanHome) }
    }

    /// Reads the workspace's state again (after a folder is chosen, or a fetch).
    func refreshWorkspace() {
        workspace = currentWorkspace?.state() ?? .noFolder
    }

    /// From the click until the result is recorded, both Lean runs and the reading between them included.
    func isChecking(problem: UUID) -> Bool { checks[problem] != nil || tools.isRunning(.lean(problem: problem)) }

    // MARK: Checking

    /// The module a check of `statement` with `candidate` would run: every statement of the problem whose code was
    /// checked before, with the candidate in place of the statement's own, dependencies first. Unchecked drafts of
    /// other statements are never in it.
    func module(for statementID: UUID, candidate: LeanCandidate) throws(VerificationError) -> LeanModulePlan {
        let (statement, source, _, _) = try resolve(statementID, candidate)
        return try module(around: statement, candidate: source)
    }

    /// A candidate's code as it stands, refused by the gate or not: what editing it starts from.
    func source(of statementID: UUID, candidate: LeanCandidate) throws(VerificationError) -> LeanSource {
        try resolve(statementID, candidate).1
    }

    /// Checks the problem's module with the statement's candidate code. `shown` is the digest of the module the person
    /// looked at when they clicked; anything else is refused. Returns at once; the result is recorded when Lean ends.
    func check(_ statementID: UUID, candidate: LeanCandidate, shown: TextDigest) throws(VerificationError) {
        let (statement, source, author, draftID) = try resolve(statementID, candidate)
        guard let problem = statement.problem else { throw .noSuchStatement }
        guard !isChecking(problem: problem.stableID) else { throw .checkRunning }
        refreshWorkspace()
        guard let workspaceFolder = currentWorkspace, let record = workspace.record else {
            throw .workspace(workspace.refusal ?? LeanWorkspaceState.noFolder.refusal ?? "")
        }
        let plan = try module(around: statement, candidate: source)
        let me = problems.me()
        let approval: Approval
        do throws(Approval.Refusal) {
            approval = try Approval.given(by: me.personID, shown: shown, stored: plan.text, at: now())
        } catch {
            throw .changedSinceShown
        }
        guard let checker = LeanCheckFiles.checkerSource else {
            throw .workspace("The app's kernel check is missing from the app. Reinstall sangaku.")
        }
        let problemID = problem.stableID
        let setup = workspaceFolder.checkSetup(record)
        let limits = settings.leanLimits
        let compileFolder = tools.newRunFolder(problem: problemID)
        let compile = SandboxJob.leanCheck(approval, problem: problemID, setup: setup, runFolder: compileFolder,
                                           limits: limits)
        let attribution = Attribution(target: statementID, author: author, draftMessageID: draftID, checkedBy: me.stableID,
                                      environment: record.environment)
        lastFailure[statementID] = nil
        checks[problemID] = Task { [weak self, tools] in
            let compiled = await tools.run(compile)
            // Only a clean compile leaves a compiled module for the kernel check to read; a missing one fails it.
            var axioms: RunReport?
            let module = compileFolder + "/" + LeanCheckFiles.compiled
            if compiled.end == .exited(0), !Task.isCancelled {
                let axiomFolder = tools.newRunFolder(problem: problemID)
                axioms = await tools.run(.leanAxioms(problem: problemID, setup: setup, compiledModule: module,
                                                     checker: checker, imports: plan.imports,
                                                     declarations: plan.regions.map(\.declaration),
                                                     runFolder: axiomFolder, limits: limits))
                tools.removeRunFolder(axiomFolder)
            }
            tools.removeRunFolder(compileFolder)
            let outcome = await Self.read(compiled, axioms, plan: plan)
            self?.apply(LeanRuns(compile: compiled, axioms: axioms), outcome, plan: plan, problemID: problemID,
                        attribution)
        }
    }

    func stopCheck(problem: UUID) {
        checks[problem]?.cancel()
        tools.stop(.lean(problem: problem))
    }

    /// Who and what a check records besides the outcome.
    private struct Attribution {
        var target: UUID
        var author: Author?
        var draftMessageID: UUID?
        var checkedBy: UUID
        var environment: LeanEnvironment
    }

    /// The two runs of a check: Lean compiling the module, then the kernel check if the compile was clean.
    struct LeanRuns {
        var compile: RunReport
        var axioms: RunReport?

        var seconds: Double { compile.seconds + (axioms?.seconds ?? 0) }
    }

    /// Reads Lean's output off the main actor; nil when the compile says nothing reliable. The kernel check counts only
    /// when it finished and printed all it had to say.
    @concurrent private static func read(_ compile: RunReport, _ axioms: RunReport?, plan: LeanModulePlan) async
        -> LeanModuleOutcome? {
        guard case .exited(let code) = compile.end, code == 0 || code == 1, !compile.stdout.truncated else { return nil }
        let checked = axioms.flatMap { $0.end == .exited(0) && !$0.stdout.truncated ? $0.stdout.text : nil }
        return LeanOutputReader.read(stdout: compile.stdout.text, axioms: checked, plan: plan)
    }

    /// Records what a check established. With the kernel check's report, every statement in the module is recorded.
    /// When Lean found errors there is no compiled module to check, so only the statements with errors and the one
    /// checked are recorded, none with axioms, and the others keep their last results. Anything else records nothing.
    private func apply(_ runs: LeanRuns, _ outcome: LeanModuleOutcome?, plan: LeanModulePlan, problemID: UUID,
                       _ attribution: Attribution) {
        checks[problemID] = nil
        let label = context.first(Statement.self, stableID: attribution.target)?.label ?? "the statement"
        func fail(_ reason: String) {
            lastFailure[attribution.target] = reason
            announce("The Lean check of \(label) recorded nothing. " + reason)
        }
        guard let outcome, outcome.isReadable else { return fail(Self.failure(runs.compile, outcome)) }
        let recorded: [LeanRegionOutcome]
        if outcome.axiomsChecked {
            recorded = outcome.regions
        } else if outcome.hasErrors {
            recorded = outcome.regions.filter { $0.errorCount > 0 || $0.statementID == attribution.target }
        } else {
            return fail(Self.kernelFailure(runs))
        }
        let targetErrors = outcome.region(for: attribution.target)?.errorCount ?? 0
        announce(targetErrors > 0 ? "Lean reported errors in the code of \(label)." : "The Lean check of \(label) is recorded.")
        for region in recorded {
            guard let statement = context.first(Statement.self, stableID: region.statementID),
                  statement.problem?.stableID == problemID else { continue }
            let result: LeanResult
            if let existing = statement.leanResult {
                result = existing
            } else {
                result = LeanResult()
                context.insert(result)
                statement.leanResult = result
            }
            let isTarget = region.statementID == attribution.target
            result.record(region, module: plan.digest, environment: attribution.environment,
                          checkedBy: attribution.checkedBy,
                          sourceAuthor: isTarget ? attribution.author : result.sourceAuthor,
                          draftMessageID: isTarget ? attribution.draftMessageID : result.draftMessageID,
                          duration: runs.seconds, at: Timestamps.after(result.checkedAt, now: now()))
        }
        lastFailure[attribution.target] = nil
        if let problem = context.first(Problem.self, stableID: problemID) { problems.contextChanged(of: problem) }
        saves.markDirty()
    }

    /// Why a clean compile recorded nothing: the kernel check did not run, did not finish, or did not accept the module.
    static func kernelFailure(_ runs: LeanRuns) -> String {
        guard let axioms = runs.axioms else {
            return runs.compile.end == .exited(0) ? "The check was stopped; nothing was recorded."
                : "Lean ended with an error it did not report; nothing was recorded."
        }
        let detail = axioms.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch axioms.end {
        case .exited(1): "The kernel check did not accept the module; nothing was recorded. " + String(detail.suffix(400))
        case .exited(0): "The kernel check's report could not be read; nothing was recorded."
        default: "The kernel check: " + failure(axioms, nil)
        }
    }

    /// Why a run recorded nothing, in words.
    static func failure(_ report: RunReport, _ outcome: LeanModuleOutcome?) -> String {
        if let outcome {
            if let error = outcome.moduleErrors.first {
                return "Lean reported an error outside the statements' code, so nothing was recorded: \(error.text)"
            }
            return "Lean printed output that is not its own messages, so nothing was recorded."
        }
        let detail = report.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = detail.isEmpty ? "" : " " + String(detail.suffix(300))
        return switch report.end {
        case .timedOut: "Lean did not finish in time; nothing was recorded."
        case .memoryLimit: "Lean used more memory than allowed; nothing was recorded."
        case .diskLimit: "Lean wrote more than allowed into its folder; nothing was recorded."
        case .stopped: "The check was stopped; nothing was recorded."
        case .couldNotStart(let reason): reason
        case .signaled(let signal): "Lean ended on signal \(signal); nothing was recorded." + tail
        case .exited(let code) where code == 0 || code == 1: "Lean's output was too long to read whole; nothing was recorded."
        case .exited(let code): "Lean ended with status \(code); nothing was recorded." + tail
        }
    }

    private func resolve(_ statementID: UUID, _ candidate: LeanCandidate)
        throws(VerificationError) -> (Statement, LeanSource, Author?, UUID?) {
        guard let statement = context.first(Statement.self, stableID: statementID), statement.problem != nil else {
            throw .noSuchStatement
        }
        switch candidate {
        case .draft(let messageID):
            guard let message = context.first(Message.self, stableID: messageID), message.kind == .leanDraft,
                  let draft = message.leanDraft, draft.statementID == statementID else { throw .noSuchDraft }
            return (statement, LeanSource(statementPart: draft.statementPart, proofPart: draft.proofPart),
                    message.author, messageID)
        case .typed(let source, let base):
            if let base, let original = try? resolve(statementID, base), original.1 == source {
                return (statement, source, original.2, original.3)
            }
            return (statement, source, .human(problems.me().personID), nil)
        case .current:
            guard let result = statement.leanResult, let source = result.storedSource else { throw .noLeanResult }
            return (statement, source, result.sourceAuthor, result.draftMessageID)
        }
    }

    private func module(around statement: Statement, candidate: LeanSource) throws(VerificationError) -> LeanModulePlan {
        if let refusal = LeanGate.refusal(for: candidate) { throw .gate(refusal) }
        try checkReferences(candidate, of: statement)
        var sources: [UUID: LeanSource] = [statement.stableID: candidate]
        var nodes = [LeanModuleOrder.Node(id: statement.stableID, createdAt: statement.createdAt,
                                          uses: (statement.uses ?? []).map(\.stableID))]
        for other in statement.problem?.statements ?? [] where other.stableID != statement.stableID {
            guard let source = other.leanResult?.storedSource else { continue }
            if let refusal = LeanGate.refusal(for: source) { throw .storedCodeRefused(label: other.label, refusal) }
            try checkReferences(source, of: other)
            sources[other.stableID] = source
            nodes.append(LeanModuleOrder.Node(id: other.stableID, createdAt: other.createdAt,
                                              uses: (other.uses ?? []).map(\.stableID)))
        }
        return LeanModulePlan(LeanModuleOrder.order(nodes).compactMap { id in sources[id].map { (id, $0) } })
    }

    /// A statement part names no other statement, and a proof names only statements its statement uses, directly or
    /// through what they use. So what a statement says is all in what its fidelity review compares, and its status is
    /// capped by everything its proof relies on (invariant 13).
    private func checkReferences(_ source: LeanSource, of statement: Statement) throws(VerificationError) {
        let statements = statement.problem?.statements ?? []
        func label(_ short: String) -> String {
            statements.first { LeanNaming.short($0.stableID) == short }?.label ?? "a statement no longer in the problem"
        }
        if let violation = LeanGate.referenceViolation(in: source, own: statement.stableID,
                                                      uses: statement.usesClosure.map(\.stableID)) {
            throw .namesOtherStatement(label: statement.label, named: label(violation.named),
                                       inStatementPart: violation.inStatementPart)
        }
    }

    // MARK: Fidelity

    /// A person's judgement that the checked Lean statement says (or does not say) what the informal one says, given on
    /// exactly the two texts they were shown. Written in the name of the person using the app, never a model.
    func recordFidelity(_ verdict: FidelityVerdict, statement statementID: UUID, seenLean: String, seenInformal: String,
                        comment: String? = nil) throws(VerificationError) {
        guard let statement = context.first(Statement.self, stableID: statementID), let problem = statement.problem else {
            throw .noSuchStatement
        }
        guard let result = statement.leanResult, result.checkedAt != nil, !result.leanStatementSource.isEmpty else {
            throw .noLeanResult
        }
        guard result.leanStatementSource == seenLean, statement.statementLaTeX == seenInformal else {
            throw .changedSinceShown
        }
        let review = FidelityReview(reviewer: problems.me().personID, leanStatementSource: seenLean, verdict: verdict)
        review.informalWording = seenInformal
        review.comment = comment.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let latest = ((statement.fidelityReviews ?? []).map(\.createdAt) + [result.checkedAt].compactMap { $0 }).max()
        review.createdAt = Timestamps.after(latest, now: now())
        context.insert(review)
        statement.fidelityReviews = (statement.fidelityReviews ?? []) + [review]
        problems.contextChanged(of: problem)
        saves.markDirty()
    }

    /// Withdraws my reviews of the current Lean statement on the current wording; they stay in the history and count
    /// for nothing. Only the person who gave a review withdraws it.
    func withdrawFidelity(statement statementID: UUID) throws(VerificationError) {
        guard let statement = context.first(Statement.self, stableID: statementID), let problem = statement.problem else {
            throw .noSuchStatement
        }
        let current = statement.leanResult?.leanStatementSource ?? ""
        let me = problems.me().stableID
        let reviews = statement.fidelityReviews ?? []
        let mine = reviews.filter {
            $0.reviewerID == me && $0.withdrawnAt == nil && !current.isEmpty && $0.leanStatementSource == current
                && $0.informalWording == statement.statementLaTeX
        }
        guard !mine.isEmpty else { throw .noFidelityToWithdraw }
        let at = Timestamps.after(reviews.flatMap { [$0.createdAt, $0.withdrawnAt].compactMap { $0 } }.max(), now: now())
        for review in mine { review.withdrawnAt = at }
        problems.contextChanged(of: problem)
        saves.markDirty()
    }

    // MARK: Fetching Mathlib

    /// Fetches Mathlib into the workspace: the pinned toolchain if elan lacks it, Mathlib's sources, its compiled
    /// cache, then an offline check that `import Mathlib` works in the sandbox. A person starts it; it uses the network.
    func fetchMathlib() throws(VerificationError) {
        guard fetchTask == nil else { throw .fetchRunning }
        guard let workspaceFolder = currentWorkspace else {
            throw .workspace(LeanWorkspaceState.noFolder.refusal ?? "")
        }
        guard let elan = settings.resolution(.elan).path else { throw .toolNotSetUp(.elan) }
        try workspaceFolder.prepare()
        fetch = FetchProgress(step: 0, steps: 6, title: "Preparing the workspace", isRunning: true)
        fetchTask = Task { [weak self] in
            await self?.runFetch(workspaceFolder, elan: elan)
        }
    }

    func stopFetch() {
        tools.stop(.fetch)
        fetchTask?.cancel()
    }

    private func runFetch(_ folder: LeanWorkspace, elan: String) async {
        defer {
            fetchTask = nil
            fetch.isRunning = false
            refreshWorkspace()
            if let failure = fetch.failure { announce(failure) }
        }
        let setup = folder.fetchSetup
        func step(_ number: Int, _ title: String, _ executable: String, _ arguments: [String]) async -> RunReport? {
            fetch.step = number
            fetch.title = title
            fetch.line = ""
            let report = await tools.run(.fetch(executable: executable, arguments: arguments, setup: setup, limits: .fetch)) {
                [weak self] text in
                let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.fetch.line = line } }
            }
            guard report.end == .exited(0) else {
                fetch.failure = report.end == .stopped ? "Fetching was stopped." : "\(title) failed: " + Self.failure(report, nil)
                return nil
            }
            return report
        }
        if !FileManager.default.isExecutableFile(atPath: folder.lean) {
            guard await step(1, "Installing Lean \(LeanPin.toolchain)", elan, ["toolchain", "install", LeanPin.toolchain]) != nil
            else { return }
        }
        guard await step(2, "Fetching Mathlib \(LeanPin.mathlibRev)", folder.lake, ["update"]) != nil else { return }
        guard folder.mathlibToolchain() == LeanPin.toolchain else {
            fetch.failure = "Mathlib \(LeanPin.mathlibRev) asks for another Lean than \(LeanPin.toolchain)."
            return
        }
        guard await step(3, "Fetching Mathlib's compiled files", folder.lake, ["exe", "cache", "get"]) != nil else { return }
        guard let version = await step(4, "Reading Lean's version", folder.lean, ["--version"]),
              let leanVersion = LeanWorkspace.leanVersion(from: version.stdout.text) else {
            if fetch.failure == nil { fetch.failure = "Lean's version could not be read." }
            return
        }
        guard let environment = await step(5, "Reading where Mathlib is", folder.lake, ["env", "printenv", "LEAN_PATH"]) else {
            return
        }
        let record = LeanWorkspaceRecord(
            environment: LeanEnvironment(toolchain: LeanPin.toolchain, leanVersion: leanVersion,
                                         mathlibRev: folder.mathlibRevision() ?? LeanPin.mathlibRev),
            lean: folder.lean, leanPath: LeanWorkspace.leanPath(from: environment.stdout.text), fetchedAt: now())
        guard let data = JSONColumn.encode(record), (try? data.write(to: URL(fileURLWithPath: folder.recordPath))) != nil else {
            fetch.failure = "The workspace record could not be written."
            return
        }
        // The same offline sandbox a check uses must load Mathlib, or nothing is ready.
        fetch.step = 6
        fetch.title = "Checking that Mathlib loads offline"
        let runFolder = tools.newRunFolder(problem: nil)
        let report = await tools.run(.leanProbe(setup: folder.checkSetup(record), runFolder: runFolder,
                                                limits: settings.leanLimits))
        tools.removeRunFolder(runFolder)
        guard report.end == .exited(0), !report.stdout.text.contains("\"severity\":\"error\"") else {
            try? FileManager.default.removeItem(atPath: folder.recordPath)
            fetch.failure = report.end == .stopped ? "Fetching was stopped."
                : "Mathlib does not load in the sandbox: " + Self.failure(report, nil)
            return
        }
        announce("Mathlib is fetched and loads offline.")
    }
}
