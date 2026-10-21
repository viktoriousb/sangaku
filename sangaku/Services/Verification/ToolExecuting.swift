import Foundation
import Synchronization

/// Runs a `SandboxJob` and reports how it ended. The real one starts processes; every copy of the app that is not the
/// person's own (tests, previews, the fixture) gets one that refuses, so nothing there can start a tool by accident.
nonisolated protocol ToolExecuting: Sendable {
    /// `onOutput` receives standard output as it arrives, for progress (fetching Mathlib).
    @concurrent func execute(_ job: SandboxJob, onOutput: (@Sendable (String) -> Void)?) async -> RunReport
    /// Kills every running job at once, without waiting: for quitting.
    func killAll()
}

/// Starts nothing.
nonisolated struct RefusingExecutor: ToolExecuting {
    var reason = "Tools are turned off in this copy of the app."

    @concurrent func execute(_ job: SandboxJob, onOutput: (@Sendable (String) -> Void)?) async -> RunReport {
        .couldNotStart(reason, at: Date.now)
    }

    func killAll() {}
}

/// Output kept within a limit: everything while it fits, then its start and its end, with the bytes dropped between
/// counted. The end matters: a check's last lines are its axiom reports.
nonisolated final class OutputCapture: Sendable {
    private struct State {
        var head = Data()
        var tail = Data()
        var dropped = 0
    }

    private let state = Mutex(State())
    private let half: Int

    init(limit: Int) {
        half = max(1, limit / 2)
    }

    func append(_ data: Data) {
        state.withLock { state in
            let room = half - state.head.count
            if room > 0 {
                state.head.append(data.prefix(room))
                if data.count <= room { return }
                state.tail.append(data.dropFirst(room))
            } else {
                state.tail.append(data)
            }
            if state.tail.count > half {
                let excess = state.tail.count - half
                state.dropped += excess
                state.tail.removeFirst(excess)
            }
        }
    }

    var result: CappedText {
        state.withLock { state in
            let head = String(decoding: state.head, as: UTF8.self)
            let tail = String(decoding: state.tail, as: UTF8.self)
            guard state.dropped > 0 else { return CappedText(text: head + tail) }
            return CappedText(text: head + "\n…\n" + tail, droppedBytes: state.dropped)
        }
    }
}
