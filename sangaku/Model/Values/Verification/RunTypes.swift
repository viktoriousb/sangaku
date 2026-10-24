import Foundation

/// The programs the app runs.
nonisolated enum ToolID: String, CaseIterable, Hashable, Codable, Sendable {
    case python, gap, sage, elan
    /// TeX for exports: the hashtag manuscript's build and the standalone document's check.
    case pdflatex
    /// Read-only `git status` before a manuscript is updated in place.
    case git

    init(_ tool: EvidenceTool) {
        switch tool {
        case .python: self = .python
        case .gap: self = .gap
        case .sage: self = .sage
        }
    }

    var displayName: String {
        switch self {
        case .python: "Python"
        case .gap: "GAP"
        case .sage: "Sage"
        case .elan: "elan"
        case .pdflatex: "pdfLaTeX"
        case .git: "git"
        }
    }
}

/// What a running job is about, so it can be stopped and shown.
nonisolated enum JobKey: Hashable, Sendable {
    /// A Lean check of a problem's module.
    case lean(problem: UUID)
    /// A run of a computation cell.
    case cell(UUID)
    /// Fetching Mathlib into the workspace.
    case fetch
    /// Asking a tool its version: each probe its own, so two cells starting together never refuse each other's.
    case probe(UUID)
    /// An export of a problem: the kit, the build, pdfLaTeX or git's read-only status, one at a time.
    case export(problem: UUID)
}

/// How long a job may run, how much memory its processes may hold together, how much it may write into its folders,
/// and how much output is kept.
nonisolated struct RunLimits: Hashable, Codable, Sendable {
    var seconds: Double
    var memoryBytes: UInt64
    var outputBytes: Int
    /// What the job's writable folders may hold; nil for fetching Mathlib, which fills the workspace.
    var folderBytes: UInt64?
    /// After asking the processes to stop, how long before they are killed.
    var killGraceSeconds: Double = 2

    static let lean = RunLimits(seconds: 600, memoryBytes: 8 << 30, outputBytes: 2 << 20, folderBytes: 1 << 30)
    static let compute = RunLimits(seconds: 120, memoryBytes: 2 << 30, outputBytes: 1 << 20, folderBytes: 1 << 30)
    static let fetch = RunLimits(seconds: 2 * 3600, memoryBytes: 8 << 30, outputBytes: 256 << 10, folderBytes: nil)
    static let probe = RunLimits(seconds: 15, memoryBytes: 512 << 20, outputBytes: 16 << 10, folderBytes: 64 << 20)
    /// The kit's build: pdfLaTeX up to six times, BibTeX and the kit's checks.
    static let export = RunLimits(seconds: 300, memoryBytes: 2 << 30, outputBytes: 1 << 20, folderBytes: 512 << 20)
    /// `kit.py new`, and git's status.
    static let kit = RunLimits(seconds: 30, memoryBytes: 512 << 20, outputBytes: 64 << 10, folderBytes: 64 << 20)
    /// git writing a repository: its `.git` can be any size, so only time and memory are limited.
    static let git = RunLimits(seconds: 60, memoryBytes: 1 << 30, outputBytes: 64 << 10, folderBytes: nil)
}

/// Output as kept: all of it, or its start and its end with what was dropped between counted.
nonisolated struct CappedText: Hashable, Sendable {
    var text: String
    var droppedBytes: Int = 0

    var truncated: Bool { droppedBytes > 0 }
}

/// How a job ended, as the runner saw it. The runner reports facts; the service that asked decides what they mean.
nonisolated enum RunEnd: Hashable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    case timedOut
    case memoryLimit
    /// It wrote more into its folders than allowed.
    case diskLimit
    /// A person stopped it, or the app quit or deleted its problem.
    case stopped
    case couldNotStart(String)
}

nonisolated struct RunReport: Hashable, Sendable {
    var end: RunEnd
    var stdout: CappedText
    var stderr: CappedText
    var startedAt: Date
    var seconds: Double
    var peakMemoryBytes: UInt64 = 0

    static func couldNotStart(_ reason: String, at date: Date) -> RunReport {
        RunReport(end: .couldNotStart(reason), stdout: CappedText(text: ""), stderr: CappedText(text: ""),
                  startedAt: date, seconds: 0)
    }

    /// Maps the runner's facts onto what a computation's evidence records.
    var outcome: RunOutcome {
        switch end {
        case .exited(0): .completed
        case .exited: .exitedNonzero
        case .signaled: .exitedNonzero
        case .timedOut: .timedOut
        case .memoryLimit: .memoryLimit
        case .diskLimit: .diskLimit
        case .stopped: .stopped
        case .couldNotStart: .couldNotRun
        }
    }
}
