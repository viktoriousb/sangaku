import Foundation
import SwiftData

/// Computations in the app: running a cell's code on a person's click, recording every run as evidence, and the cells a
/// person writes or edits. The only writer of `Evidence` and of person-written cells. A cell's code runs only as the
/// exact text shown when Run was clicked, offline in the sandbox (invariant 14); what it reports changes no status
/// (invariant 1).
@Observable
final class ComputeService {
    /// Why the last Run of a cell did not start, until the next one does.
    private(set) var lastFailure: [UUID: String] = [:]
    /// The cells running now, from the click until the run is recorded (the version probe before it included).
    private(set) var running: Set<UUID> = []

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let saves: SaveScheduler
    @ObservationIgnored let problems: ProblemManager
    @ObservationIgnored let tools: ToolRunner
    @ObservationIgnored let settings: ToolSettings
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// The problem of each running cell, so deleting a problem stops its cells.
    @ObservationIgnored private var cellProblems: [UUID: UUID] = [:]
    @ObservationIgnored private var versions: [String: String] = [:]
    @ObservationIgnored private let now: () -> Date
    /// Says how a run ended, for VoiceOver: it ends long after the click.
    @ObservationIgnored private let announce: (String) -> Void

    init(context: ModelContext, saves: SaveScheduler, problems: ProblemManager, tools: ToolRunner,
         settings: ToolSettings, now: @escaping () -> Date = { .now }, announce: @escaping (String) -> Void = { _ in }) {
        self.context = context
        self.saves = saves
        self.problems = problems
        self.tools = tools
        self.settings = settings
        self.now = now
        self.announce = announce
    }

    isolated deinit {
        tasks.values.forEach { $0.cancel() }
    }

    func isRunning(cell: UUID) -> Bool { running.contains(cell) || tools.isRunning(.cell(cell)) }

    /// Where a cell stands.
    func state(of cell: ComputeCell) -> CellState {
        if isRunning(cell: cell.stableID) { return .running }
        guard let latest = cell.latestRun else { return .waiting }
        return .ran(outcome: latest.outcome, verdict: latest.verdict)
    }

    /// Runs a cell's stored code. `shown` is the digest of the code the person was looking at when they clicked Run;
    /// anything else is refused. Returns at once; the run is recorded when it ends.
    func run(cell messageID: UUID, shown: TextDigest) throws(VerificationError) {
        guard let message = context.first(Message.self, stableID: messageID), message.kind == .compute,
              let cell = message.computeCell, let problem = message.branch?.problem else { throw .noSuchCell }
        guard let statementID = cell.statementID, let statement = context.first(Statement.self, stableID: statementID),
              statement.problem?.stableID == problem.stableID else { throw .noStatementAttached }
        guard !isRunning(cell: cell.stableID) else { throw .cellRunning }
        let tool = ToolID(cell.tool)
        let executable: String
        switch settings.resolution(tool) {
        case .ready(let path, _): executable = path
        case .notSetUp: throw .toolNotSetUp(tool)
        case .notExecutable(let path): throw .toolNotUsable(tool, "\(path) is not a program that can be run.")
        }
        let me = problems.me()
        let approval: Approval
        do throws(Approval.Refusal) {
            approval = try Approval.given(by: me.personID, shown: shown, stored: cell.code, at: now())
        } catch {
            throw .changedSinceShown
        }
        let runFolder = tools.newRunFolder(problem: problem.stableID)
        let job = SandboxJob.compute(approval, cell: cell.stableID, problem: problem.stableID, tool: cell.tool,
                                     executable: executable, toolRoot: settings.locator.installationRoot(of: executable),
                                     runFolder: runFolder, limits: settings.computeLimits)
        let cellID = cell.stableID
        let runBy = me.stableID
        lastFailure[cellID] = nil
        running.insert(cellID)
        cellProblems[cellID] = problem.stableID
        tasks[cellID] = Task { [weak self, tools] in
            let version = await self?.version(of: tool, executable: executable) ?? ""
            // Stopped before the run started: nothing ran, so nothing is recorded.
            guard !Task.isCancelled else {
                self?.finish(cellID)
                return
            }
            let report = await tools.run(job)
            tools.removeRunFolder(runFolder)
            self?.record(report, cell: cellID, code: approval.text, runBy: runBy, toolVersion: version)
        }
    }

    func stop(cell: UUID) {
        tasks[cell]?.cancel()
        tools.stop(.cell(cell))
    }

    /// Stops every running cell of a problem being deleted, the version probe before a run included.
    func cancelAll(problemID: UUID) {
        for (cell, problem) in cellProblems where problem == problemID { stop(cell: cell) }
    }

    private func finish(_ cellID: UUID) {
        tasks[cellID] = nil
        running.remove(cellID)
        cellProblems[cellID] = nil
    }

    /// Writes one run as evidence on the cell's statement: the code that ran, what it printed, how it ended and what it
    /// reported. A run that could not start is not evidence; the reason is shown instead.
    private func record(_ report: RunReport, cell cellID: UUID, code: String, runBy: UUID, toolVersion: String) {
        finish(cellID)
        if case .couldNotStart(let reason) = report.end {
            lastFailure[cellID] = reason
            announce("The computation could not start. " + reason)
            return
        }
        guard let cell = context.first(ComputeCell.self, stableID: cellID), let statementID = cell.statementID,
              let statement = context.first(Statement.self, stableID: statementID) else { return }
        announce("The computation on \(statement.label) has ended; its run is in the thread.")
        let outcome = report.outcome
        let verdict = outcome == .completed ? CellOutputReader.read(report.stdout.text).verdict : .inconclusive
        let evidence = Evidence(tool: cell.tool, code: code, output: report.stdout.text,
                                passed: outcome == .completed && verdict == .holds, scope: cell.scope)
        evidence.errorText = report.stderr.text
        evidence.outcome = outcome
        evidence.verdict = verdict
        evidence.exitCode = if case .exited(let status) = report.end { Int(status) } else { nil }
        evidence.durationSeconds = report.seconds
        evidence.truncated = report.stdout.truncated || report.stderr.truncated
        evidence.startedAt = report.startedAt
        evidence.runByID = runBy
        evidence.toolVersion = toolVersion
        let latest = ((statement.evidence ?? []).map(\.createdAt) + [cell.createdAt]).max()
        evidence.createdAt = Timestamps.after(latest, now: now())
        context.insert(evidence)
        evidence.cell = cell
        statement.evidence = (statement.evidence ?? []) + [evidence]
        saves.markDirty()
    }

    /// The tool's version, offline, kept once a probe of the program has told it; a probe that fails is asked again next
    /// time. Each run asks in its own task, so Stop stops the probe too. Empty when it cannot be told.
    private func version(of tool: ToolID, executable: String) async -> String {
        guard tool == .python else { return "" }
        if let known = versions[executable] { return known }
        let runFolder = tools.newRunFolder(problem: nil)
        let report = await tools.run(.probe(tool, executable: executable, arguments: ["--version"],
                                            toolRoot: settings.locator.installationRoot(of: executable), runFolder: runFolder))
        tools.removeRunFolder(runFolder)
        let text = (report.stdout.text + report.stderr.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard report.end == .exited(0), !text.isEmpty else { return "" }
        versions[executable] = String(text.prefix(60))
        return String(text.prefix(60))
    }

    /// A cell a person writes, or edits from another: a new computation message by them on the branch, attached to a
    /// statement. The code is theirs; it still runs only when they click Run on it.
    @discardableResult
    func writeCell(on branch: Branch, statement statementID: UUID, tool: EvidenceTool, code: String, scope: String,
                   claim: String, basedOn: UUID? = nil) throws(VerificationError) -> UUID {
        guard let problem = branch.problem, let statement = context.first(Statement.self, stableID: statementID),
              statement.problem?.stableID == problem.stableID else { throw .noStatementAttached }
        if let reason = CodeText.refusal(code) { throw .invalid(reason) }
        let text = code
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalid("The code is empty.") }
        let scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty else { throw .invalid("Say exactly what the computation covers.") }
        let message = Message(author: .human(problems.me().personID), bodyLaTeX: "", kind: .compute)
        message.createdAt = Timestamps.after(branch.visibleHistory.latestDate, now: now())
        let cell = ComputeCell(tool: tool, code: text, scope: scope, claim: claim.trimmingCharacters(in: .whitespacesAndNewlines),
                               statementID: statementID)
        cell.basedOnCellID = basedOn
        cell.createdAt = message.createdAt
        context.insert(message)
        message.computeCell = cell
        branch.messages = (branch.messages ?? []) + [message]
        saves.markDirty()
        return message.stableID
    }
}
