import Foundation

/// The Anthropic Messages API on the wire: the request body, the stream's events and the error responses.
/// Pure functions, tested without a network.
nonisolated enum AnthropicWire {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    /// How thinking is requested: the model decides how long to think (`effort` sets how hard), and its
    /// reasoning is not displayed. Opus 5.5 cannot turn thinking off.
    static let thinkingDescription = "adaptive, not displayed"

    // MARK: Request

    /// Encoded with snake-case keys (`maxTokens` becomes `max_tokens`).
    private struct Body: Encodable {
        struct TextBlock: Encodable {
            struct CacheControl: Encodable { let type = "ephemeral" }
            let type = "text"
            let text: String
            var cacheControl: CacheControl?
        }
        struct Turn: Encodable {
            let role: String
            let content: [TextBlock]
        }
        struct OutputConfig: Encodable {
            struct Format: Encodable {
                let type = "json_schema"
                let schema: String
            }
            let effort: String
            var format: Format?
        }

        let model: String
        let maxTokens: Int
        let stream = true
        let system: [TextBlock]
        let messages: [Turn]
        let outputConfig: OutputConfig
    }

    static func body(_ request: ProviderRequest) -> Data {
        let body = Body(
            model: request.modelID,
            maxTokens: request.maxOutputTokens,
            system: request.system.map {
                Body.TextBlock(text: $0.text, cacheControl: $0.cacheBreakpoint ? .init() : nil)
            },
            messages: request.turns.map { turn in
                Body.Turn(role: turn.role.rawValue, content: turn.blocks.map { Body.TextBlock(text: $0) })
            },
            outputConfig: .init(effort: request.effort.rawValue,
                                format: request.format.map { _ in .init(schema: schemaPlaceholder) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        // Encoding plain strings and integers cannot fail.
        let encoded = (try? encoder.encode(body)) ?? Data()
        guard let format = request.format else { return encoded }
        // The schema goes in exactly as written: encoded through `Body`, the snake-case key strategy would rewrite
        // its keywords (`additionalProperties`), and re-serializing it would reorder its properties.
        return Data(String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "\"\(schemaPlaceholder)\"", with: format.schemaJSON).utf8)
    }

    /// Stands in for the schema while the body is encoded: a fresh UUID each launch, so no text in a request
    /// contains it.
    private static let schemaPlaceholder = "sangaku-output-schema-" + UUID().uuidString

    /// The only place the key is used: one request header.
    static func urlRequest(_ request: ProviderRequest, apiKey: String) -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.httpBody = body(request)
        return urlRequest
    }

    // MARK: Errors

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let type: String?
            let message: String?
        }
        let error: Detail?
    }

    /// Maps a non-200 response. The body is the provider's JSON error, or whatever text came back.
    static func error(status: Int, headers: [String: String], body: Data) -> ProviderError {
        let detail = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error
        let fallback = String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail?.message ?? (fallback.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : fallback)
        if status == 529 || detail?.type == "overloaded_error" { return .overloaded(message) }
        let retryAfter = headers["retry-after"].flatMap(Double.init)
        return .http(status: status, kind: detail?.type, message: message, retryAfter: retryAfter)
    }
}

/// Turns the stream's events into `ProviderEvent`s. The reply is finished at `message_stop`; a stream that
/// ends after the stop reason arrived but before `message_stop` still counts as finished.
nonisolated struct AnthropicEventDecoder {
    private var usage = TokenUsage()
    private var stopReason: StopReason?
    private var announcedThinking = false
    private(set) var isFinished = false

    /// Decoded from snake-case keys (`stop_reason` becomes `stopReason`).
    private struct Payload: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let outputTokens: Int?
        }
        struct MessageStart: Decodable {
            let model: String?
            let usage: Usage?
        }
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct Delta: Decodable {
            struct StopDetails: Decodable { let category: String? }
            let type: String?
            let text: String?
            let stopReason: String?
            let stopDetails: StopDetails?
        }
        struct Failure: Decodable {
            let type: String?
            let message: String?
        }

        let type: String
        let message: MessageStart?
        let contentBlock: Block?
        let delta: Delta?
        let usage: Usage?
        let error: Failure?
    }

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    mutating func decode(_ event: SSEEvent) throws -> [ProviderEvent] {
        guard !isFinished else { return [] }
        let payload: Payload
        do {
            payload = try Self.jsonDecoder.decode(Payload.self, from: Data(event.data.utf8))
        } catch {
            throw ProviderError.malformedStream("an event could not be decoded (\(event.event ?? "no name"))")
        }
        switch payload.type {
        case "message_start":
            merge(payload.message?.usage)
            return [.started(answeredModel: payload.message?.model ?? "", usage: usage)]
        case "content_block_start":
            switch payload.contentBlock?.type {
            case "thinking", "redacted_thinking":
                return thinking()
            case "text":
                if let text = payload.contentBlock?.text, !text.isEmpty { return [.text(text)] }
                return []
            default:
                return []
            }
        case "content_block_delta":
            switch payload.delta?.type {
            case "text_delta":
                if let text = payload.delta?.text, !text.isEmpty { return [.text(text)] }
                return []
            case "thinking_delta", "signature_delta":
                return thinking()
            default:
                return []
            }
        case "message_delta":
            merge(payload.usage)
            if let wire = payload.delta?.stopReason {
                stopReason = StopReason(wire: wire, category: payload.delta?.stopDetails?.category)
            }
            return []
        case "message_stop":
            isFinished = true
            return [.finished(stopReason ?? .other("unknown"), usage)]
        case "error":
            let kind = payload.error?.type ?? "error"
            let message = payload.error?.message ?? "no details"
            throw kind == "overloaded_error" ? ProviderError.overloaded(message) : ProviderError.stream(kind: kind, message: message)
        default:
            // ping, content_block_stop, and event types added later
            return []
        }
    }

    /// The stream ended. Without a stop reason the reply is incomplete.
    mutating func finish() throws -> [ProviderEvent] {
        guard !isFinished else { return [] }
        guard let stopReason else { throw ProviderError.incomplete }
        isFinished = true
        return [.finished(stopReason, usage)]
    }

    private mutating func thinking() -> [ProviderEvent] {
        guard !announcedThinking else { return [] }
        announcedThinking = true
        return [.thinking]
    }

    /// Usage fields arrive in `message_start` and, cumulatively, in `message_delta`. A field present later
    /// replaces the earlier value.
    private mutating func merge(_ reported: Payload.Usage?) {
        guard let reported else { return }
        if let value = reported.inputTokens { usage.input = value }
        if let value = reported.cacheCreationInputTokens { usage.cacheWrite = value }
        if let value = reported.cacheReadInputTokens { usage.cacheRead = value }
        if let value = reported.outputTokens { usage.output = value }
    }
}
