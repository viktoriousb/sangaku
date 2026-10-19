import Foundation

/// The words above a fan-out's attempt cards: how many attempts and where they stand, who could see whom, and what
/// the referee is doing. Pure, from facts the thread already has.
nonisolated struct FanOutHeader: Hashable, Sendable {
    nonisolated enum AttemptState: Hashable, Sendable {
        case queued, running, finished, stopped, cutOff, failed, declined, endedEarly
    }

    nonisolated struct Attempt: Hashable, Sendable {
        var letter: String
        var state: AttemptState
    }

    nonisolated enum RefereeState: Hashable, Sendable {
        /// No referee was chosen for this fan-out.
        case none
        /// Starts once every attempt has ended.
        case waiting
        case running
        /// A referee gave its verdicts.
        case done
        /// The latest referee ended without verdicts that could be read (it failed, was stopped or wrote something
        /// else).
        case noVerdicts
        /// Chosen, but it has not run: Stop all cancelled it, or the app closed first.
        case notRun
    }

    var title: String
    var visibilityLine: String
    var refereeLine: String?

    init(visibility: FanOutVisibility, attempts: [Attempt], refereeLetter: String?, referee: RefereeState) {
        let count = attempts.count
        let kind = visibility == .independent ? "independent" : "shared"
        title = "\(count) \(kind) attempt\(count == 1 ? "" : "s") · " + Self.progress(attempts)
        let letters = attempts.map(\.letter)
        visibilityLine = switch (visibility, count) {
        case (_, 0), (_, 1): "One attempt"
        case (.independent, _): "Independent: \(Prose.list(letters)) can't see each other"
        case (.shared, _): "Shared: each sees the attempts before it (\(letters.joined(separator: ", then ")))"
        }
        let them = count == 1 ? "it" : count == 2 ? "both" : "all"
        let waitFor = count == 1 ? letters.first ?? "the attempt" : count == 2 ? "both" : "all"
        refereeLine = switch (referee, refereeLetter) {
        case (.none, _), (_, nil): nil
        case (.waiting, let letter?): "\(letter) waits for \(waitFor), then sees \(them)"
        case (.running, let letter?): "\(letter) is refereeing \(them)"
        case (.done, let letter?): "\(letter) refereed \(them) after they ended"
        case (.noVerdicts, let letter?): "\(letter) gave no verdicts that could be read"
        case (.notRun, let letter?): "\(letter) has not refereed"
        }
    }

    private static func progress(_ attempts: [Attempt]) -> String {
        if !attempts.isEmpty, attempts.allSatisfy({ $0.state == .finished }) {
            return attempts.count == 1 ? "finished" : attempts.count == 2 ? "both finished" : "all finished"
        }
        var parts: [String] = []
        let running = attempts.filter { $0.state == .running }.count
        let queued = attempts.filter { $0.state == .queued }.count
        if running > 0 { parts.append("\(running) running") }
        if queued > 0 { parts.append("\(queued) waiting") }
        for (state, word) in [(AttemptState.stopped, "stopped"), (.cutOff, "cut off"), (.failed, "failed"),
                              (.declined, "declined"), (.endedEarly, "ended early")] {
            let letters = attempts.filter { $0.state == state }.map(\.letter)
            if !letters.isEmpty { parts.append("\(Prose.list(letters)) \(word)") }
        }
        let finished = attempts.filter { $0.state == .finished }.count
        if finished > 0 { parts.append("\(finished) finished") }
        return parts.joined(separator: ", ")
    }
}

nonisolated extension FanOutHeader.AttemptState {
    /// An attempt's state from its outcome, or from its live stream while it runs.
    init(outcome: MessageOutcome, queued: Bool) {
        if queued {
            self = .queued
            return
        }
        self = switch outcome {
        case .streaming: .running
        case .complete: .finished
        case .interrupted: .stopped
        case .cutOff: .cutOff
        case .failed: .failed
        case .declined: .declined
        case .endedEarly: .endedEarly
        }
    }
}
