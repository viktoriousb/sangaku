import Foundation

/// Tokens of one request, as the provider bills them. `input` excludes cached tokens, so the whole prompt is
/// `promptTotal`.
nonisolated struct TokenUsage: Hashable, Codable, Sendable {
    var input = 0
    var cacheWrite = 0
    var cacheRead = 0
    var output = 0

    var promptTotal: Int { input + cacheWrite + cacheRead }
}

/// Why a model stopped writing.
nonisolated enum StopReason: Hashable, Sendable {
    case endTurn
    case maxTokens
    case stopSequence
    /// The provider's safety system declined the request. Nothing else answers in the slot's name.
    case refusal(category: String?)
    case other(String)

    init(wire: String, category: String?) {
        switch wire {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "refusal": self = .refusal(category: category)
        default: self = .other(wire)
        }
    }

    /// The value stored in `RequestRecord.stopReason`.
    var stored: String {
        switch self {
        case .endTurn: "end_turn"
        case .maxTokens: "max_tokens"
        case .stopSequence: "stop_sequence"
        case .refusal: "refusal"
        case .other(let raw): raw
        }
    }

    var category: String? {
        if case .refusal(let category) = self { category } else { nil }
    }
}

/// Why a request ended when the provider did not say, as stored in `RequestRecord.stopReason`.
nonisolated enum LocalStopReason: String, CaseIterable, Sendable {
    /// A person pressed Stop.
    case stopped
    /// sangaku quit while the reply streamed.
    case appQuit = "app_quit"
    /// sangaku closed (or crashed) before the request ended; found on the next load.
    case orphaned
}

/// What a provider reports while a reply streams.
nonisolated enum ProviderEvent: Hashable, Sendable {
    /// The provider accepted the request: the model that answers and the input side of the usage.
    case started(answeredModel: String, usage: TokenUsage)
    /// The model is thinking. Its reasoning is not shown, only that it is happening.
    case thinking
    case text(String)
    /// The reply ended normally (which includes a refusal), with the final usage.
    case finished(StopReason, TokenUsage)
}

/// A request that failed. `message` is written for the person using the app and never contains the key.
nonisolated enum ProviderError: Error, Hashable, Sendable {
    case missingKey
    case http(status: Int, kind: String?, message: String, retryAfter: Double?)
    case overloaded(String)
    /// An `error` event in the middle of a stream.
    case stream(kind: String, message: String)
    case transport(String)
    /// The key could not be read from the Keychain (denied, locked or unreadable).
    case keychain(String)
    case malformedStream(String)
    /// The connection closed before the reply finished.
    case incomplete

    /// The value stored in `RequestRecord.errorKind`.
    var kind: String {
        switch self {
        case .missingKey: "missing_key"
        case .http(let status, let kind, _, _): kind ?? "http_\(status)"
        case .overloaded: "overloaded_error"
        case .stream(let kind, _): kind
        case .transport: "network"
        case .keychain: "keychain_error"
        case .malformedStream: "malformed_stream"
        case .incomplete: "incomplete"
        }
    }

    var message: String {
        switch self {
        case .missingKey:
            "No API key is stored. Add one in Settings."
        case .http(let status, let kind, let message, let retryAfter):
            switch status {
            case 401: "The API key was rejected: \(message)"
            case 403: "The API key may not use this model: \(message)"
            case 404: "The model was not found: \(message)"
            case 413: "The request is too large: \(message)"
            case 429:
                if let retryAfter { "Rate limited. Try again in \(Int(retryAfter.rounded(.up))) s. \(message)" }
                else { "Rate limited. \(message)" }
            case 500...: "The provider had an error (\(status)): \(message)"
            default: "The request was refused (\(kind ?? "HTTP \(status)")): \(message)"
            }
        case .overloaded(let message):
            "The provider is overloaded. Try again shortly."
                + (message.caseInsensitiveCompare("Overloaded") == .orderedSame ? "" : " \(message)")
        case .stream(let kind, let message):
            "The reply stopped with an error (\(kind)): \(message)"
        case .transport(let message):
            "The connection failed: \(message)"
        case .keychain(let message):
            "The API key could not be read from the keychain: \(message)"
        case .malformedStream(let message):
            "The provider sent a reply that could not be read: \(message)"
        case .incomplete:
            "The connection closed before the reply finished."
        }
    }

    /// The error means the key needs attention in Settings.
    var concernsKey: Bool { Self.kindConcernsKey(kind) }

    /// For an error kind as stored in `RequestRecord.errorKind`.
    static func kindConcernsKey(_ kind: String) -> Bool {
        ["missing_key", "keychain_error", "authentication_error", "permission_error", "http_401", "http_403"].contains(kind)
    }
}

/// How hard the model thinks before it answers (the API's `output_config.effort`).
nonisolated enum ThinkingEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case low, medium, high, xhigh, max

    static let standard = ThinkingEffort.high

    var id: Self { self }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }
}

/// One block of the stable part of a request (the system prompt). The block with `cacheBreakpoint` ends the
/// part the provider may cache.
nonisolated struct SystemBlock: Hashable, Sendable {
    var text: String
    var cacheBreakpoint: Bool
}

/// Exactly what a provider is asked. It can only be made from a `BuiltContext`, which only `ContextBuilder`
/// makes, after it has checked the problem's provider policy (invariant 15). It never holds a key.
nonisolated struct ProviderRequest: Hashable, Sendable {
    let providerID: String
    let modelID: String
    let system: [SystemBlock]
    let turns: [ContextTurn]
    let effort: ThinkingEffort
    let maxOutputTokens: Int
    /// The structured output asked for, taken from the context: a request built for a structured prompt always
    /// carries its schema.
    let format: OutputFormat?

    init(_ context: BuiltContext, modelID: String, effort: ThinkingEffort, maxOutputTokens: Int) {
        providerID = context.providerID
        self.modelID = modelID
        system = context.stable.enumerated().map { index, section in
            SystemBlock(text: section.text, cacheBreakpoint: index == context.stable.count - 1)
        }
        turns = context.turns
        self.effort = effort
        self.maxOutputTokens = maxOutputTokens
        format = context.format
    }
}

/// The parameters a request was sent with, stored as `RequestRecord.parametersJSON`.
nonisolated struct RequestParameters: Codable, Hashable, Sendable {
    var model: String
    var maxOutputTokens: Int
    var effort: ThinkingEffort
    var stream: Bool
    var apiVersion: String?
    /// How the model's thinking was requested and shown, e.g. "adaptive, not displayed".
    var thinking: String?
    /// The structured output asked for, e.g. "proof-attempt@1"; nil for prose.
    var outputFormat: String?
}
