import Foundation

/// How a message's request ended. Derived from what is stored, never stored itself.
nonisolated enum MessageOutcome: Hashable, Sendable {
    /// A reply still streaming in this session.
    case streaming
    /// Written by a person, or a reply that finished normally.
    case complete
    /// The provider declined the request.
    case declined(category: String?)
    case failed(kind: String, message: String)
    /// Stopped before it finished; whatever arrived is kept. Also a request whose app quit or crashed.
    case interrupted
    /// The reply reached the output limit (or the context window) and is cut off.
    case cutOff
    /// The provider ended the reply for a reason the app does not know as complete.
    case endedEarly(reason: String)

    /// The first rule that matches: streaming, declined, failed, interrupted (including a request that never
    /// finished), cut off, ended early, complete. Only a stop reason known to mean "finished" reads as complete.
    static func resolve(isStreaming: Bool, interrupted: Bool, hasRequest: Bool, finished: Bool,
                        stopReason: String?, stopCategory: String?, errorKind: String?,
                        errorMessage: String?) -> MessageOutcome {
        if isStreaming { return .streaming }
        if stopReason == "refusal" { return .declined(category: stopCategory) }
        if let errorKind { return .failed(kind: errorKind, message: errorMessage ?? errorKind) }
        if interrupted || (hasRequest && !finished) { return .interrupted }
        switch stopReason {
        case nil, "end_turn", "stop_sequence":
            return .complete
        case "max_tokens", "model_context_window_exceeded":
            return .cutOff
        case let reason?:
            return LocalStopReason(rawValue: reason) == nil ? .endedEarly(reason: reason) : .interrupted
        }
    }

    /// Whatever arrived is incomplete, so a model reading it later is told so.
    var isPartial: Bool {
        switch self {
        case .interrupted, .cutOff, .endedEarly, .failed: true
        case .streaming, .complete, .declined: false
        }
    }
}

extension Message {
    func outcome(isStreaming: Bool) -> MessageOutcome {
        MessageOutcome.resolve(isStreaming: isStreaming, interrupted: interrupted, hasRequest: request != nil,
                               finished: request?.finishedAt != nil, stopReason: request?.stopReason,
                               stopCategory: request?.stopCategory, errorKind: request?.errorKind,
                               errorMessage: request?.errorMessage)
    }
}
