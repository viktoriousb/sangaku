import Foundation
import Testing
@testable import sangaku

@Suite("SSE parser")
struct SSEParserTests {
    private let stream = "event: a\r\ndata: {\"x\": \"≡ ∣\"}\r\n\r\n: a comment\nevent: b\ndata: one\ndata: two\n\nevent: c\rdata: three\r\r"
    private let expected = [
        SSEEvent(event: "a", data: "{\"x\": \"≡ ∣\"}"),
        SSEEvent(event: "b", data: "one\ntwo"),
        SSEEvent(event: "c", data: "three"),
    ]

    private func parse(_ chunks: [Data]) -> [SSEEvent] {
        var parser = SSEParser()
        return chunks.flatMap { parser.feed($0) } + parser.finish()
    }

    @Test("The same events at every split point, including inside a UTF-8 character and between CR and LF")
    func everySplitPoint() {
        let bytes = Array(stream.utf8)
        #expect(parse([Data(bytes)]) == expected)
        for split in 0...bytes.count {
            #expect(parse([Data(bytes[..<split]), Data(bytes[split...])]) == expected, "split at \(split)")
        }
        #expect(parse(bytes.map { Data([$0]) }) == expected)
    }

    @Test("Streams without blank lines still separate events, and the end flushes the last one")
    func withoutBlankLines() {
        let events = parse([Data("event: a\ndata: 1\nevent: b\ndata: 2".utf8)])
        #expect(events == [SSEEvent(event: "a", data: "1"), SSEEvent(event: "b", data: "2")])
    }
}

@Suite("Anthropic wire format")
struct AnthropicWireTests {
    private func request(effort: ThinkingEffort = .high) throws -> ProviderRequest {
        let fixture = PreviewFixtures.make()
        let snapshot = ProblemSnapshot.make(problem: fixture.problem, branch: fixture.mainBranch,
                                            notation: fixture.state.problems.notation(for: fixture.problem),
                                            people: [fixture.you, fixture.mk], liveMessageIDs: [])
        let built = try ContextBuilder().build(ContextInput(
            snapshot: snapshot, providerID: ProviderID.anthropic, purpose: .reply(slot: fixture.slotA.slotID, fanOut: nil),
            rolePrompt: try #require(PromptLibrary.bundled.prompt(for: .prover)), pending: "Next?", inputBudget: nil))
        return ProviderRequest(built, modelID: "claude-opus-5-5", effort: effort, maxOutputTokens: 64_000)
    }

    @Test("The body: one cache breakpoint at the end of the stable part, effort, no thinking or sampling settings")
    func body() throws {
        let body = AnthropicWire.body(try request(effort: .xhigh))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["max_tokens"] as? Int == 64_000)
        #expect(json["stream"] as? Bool == true)
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "xhigh")
        for absent in ["thinking", "temperature", "top_p", "top_k"] { #expect(json[absent] == nil, "\(absent) sent") }
        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.count == ContextSectionKind.allCases.count)
        #expect(system.dropLast().allSatisfy { $0["cache_control"] == nil })
        #expect((system.last?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.last?["role"] as? String == "user", "no assistant prefill")
    }

    @Test("The key goes into one header and nowhere else")
    func keyOnlyInHeader() throws {
        let urlRequest = AnthropicWire.urlRequest(try request(), apiKey: "sk-test-SENTINEL")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-test-SENTINEL")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(urlRequest.url == AnthropicWire.endpoint)
        #expect(!String(decoding: urlRequest.httpBody ?? Data(), as: UTF8.self).contains("SENTINEL"))
    }

    private func decode(_ transcript: String) throws -> [ProviderEvent] {
        var parser = SSEParser()
        var decoder = AnthropicEventDecoder()
        var events: [ProviderEvent] = []
        for event in parser.feed(Data(transcript.utf8)) + parser.finish() { events += try decoder.decode(event) }
        return events + (try decoder.finish())
    }

    @Test("A stream with a hidden thinking block, text and cached usage")
    func decodesStream() throws {
        let events = try decode(SSE.start(input: 40, cacheWrite: 0, cacheRead: 2_000) + SSE.thinking + SSE.ping
                                + SSE.text("Let $G$", " be a group.") + SSE.delta("end_turn", output: 300) + SSE.stop)
        let usage = TokenUsage(input: 40, cacheWrite: 0, cacheRead: 2_000, output: 300)
        #expect(events == [
            .started(answeredModel: "claude-opus-5-5", usage: TokenUsage(input: 40, cacheRead: 2_000, output: 1)),
            .thinking, .text("Let $G$"), .text(" be a group."), .finished(.endTurn, usage),
        ])
    }

    @Test("A refusal carries its category; the output limit is its own stop reason")
    func stopReasons() throws {
        let refusal = try decode(SSE.start() + SSE.delta("refusal", output: 0, category: "cyber") + SSE.stop)
        #expect(refusal.last == .finished(.refusal(category: "cyber"), TokenUsage(input: 12, output: 0)))
        let cut = try decode(SSE.start() + SSE.text("abc") + SSE.delta("max_tokens", output: 64_000) + SSE.stop)
        #expect(cut.last == .finished(.maxTokens, TokenUsage(input: 12, output: 64_000)))
    }

    @Test("A mid-stream error event throws; overloaded is told apart")
    func midStreamErrors() {
        let overloaded = SSE.start() + SSE.event("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        #expect(throws: ProviderError.overloaded("Overloaded")) { try decode(overloaded) }
        let other = SSE.start() + SSE.event("error", #"{"type":"error","error":{"type":"api_error","message":"boom"}}"#)
        #expect(throws: ProviderError.stream(kind: "api_error", message: "boom")) { try decode(other) }
    }

    @Test("A stream that ends early is incomplete, unless its stop reason already arrived")
    func earlyEnd() throws {
        #expect(throws: ProviderError.incomplete) { try decode(SSE.start() + SSE.text("partial")) }
        let events = try decode(SSE.start() + SSE.text("done") + SSE.delta("end_turn", output: 5))
        #expect(events.last == .finished(.endTurn, TokenUsage(input: 12, output: 5)))
    }

    @Test("Unknown event types are ignored")
    func unknownEvents() throws {
        let events = try decode(SSE.start() + SSE.event("future_thing", #"{"type":"future_thing","x":1}"#)
                                + SSE.text("a") + SSE.delta("end_turn", output: 1) + SSE.stop)
        #expect(events.count == 3)
    }

    @Test("HTTP errors map to readable messages without guessing")
    func httpErrors() {
        let auth = AnthropicWire.error(status: 401, headers: [:], body: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        #expect(auth == .http(status: 401, kind: "authentication_error", message: "invalid x-api-key", retryAfter: nil))
        #expect(auth.concernsKey)
        let limited = AnthropicWire.error(status: 429, headers: ["retry-after": "12"], body: Data(#"{"error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8))
        #expect(limited == .http(status: 429, kind: "rate_limit_error", message: "slow down", retryAfter: 12))
        #expect(limited.message.contains("12 s"))
        #expect(AnthropicWire.error(status: 529, headers: [:], body: Data()).kind == "overloaded_error")
        let plain = AnthropicWire.error(status: 400, headers: [:], body: Data("bad gateway text".utf8))
        #expect(plain == .http(status: 400, kind: nil, message: "bad gateway text", retryAfter: nil))
    }
}

@Suite("Anthropic provider")
struct AnthropicProviderTests {
    private let request: ProviderRequest

    init() throws {
        let fixture = PreviewFixtures.make()
        let snapshot = ProblemSnapshot.make(problem: fixture.problem, branch: fixture.mainBranch,
                                            notation: fixture.state.problems.notation(for: fixture.problem),
                                            people: [fixture.you], liveMessageIDs: [])
        let built = try ContextBuilder().build(ContextInput(
            snapshot: snapshot, providerID: ProviderID.anthropic, purpose: .reply(slot: fixture.slotA.slotID, fanOut: nil),
            rolePrompt: try #require(PromptLibrary.bundled.prompt(for: .prover)), pending: "Go on.", inputBudget: nil))
        request = ProviderRequest(built, modelID: "claude-opus-5-5", effort: .high, maxOutputTokens: 64_000)
    }

    private func collect(_ stream: AsyncThrowingStream<ProviderEvent, any Error>) async throws -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test("Streams events end to end, with the stored key in the header only")
    func endToEnd() async throws {
        let transport = FakeTransport(body: SSE.reply("Done.", input: 9, cacheRead: 100, output: 4), chunkSize: 7)
        let secrets = InMemorySecretStore([AnthropicProvider.keyAccount: "sk-test-SENTINEL"])
        let events = try await collect(AnthropicProvider(transport: transport, secrets: secrets).stream(request))
        #expect(events.contains(.text("Done.")))
        #expect(events.last == .finished(.endTurn, TokenUsage(input: 9, cacheRead: 100, output: 4)))
        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "x-api-key") == "sk-test-SENTINEL")
    }

    @Test("A key the keychain refuses is reported as a keychain problem that needs Settings, not as a network error")
    func keychainFailure() async {
        let transport = FakeTransport(body: SSE.reply("x"))
        let provider = AnthropicProvider(transport: transport, secrets: FailingSecretStore())
        await #expect(throws: ProviderError.keychain("User interaction is not allowed.")) {
            try await collect(provider.stream(request))
        }
        #expect(transport.requests.isEmpty)
        #expect(ProviderError.keychain("x").concernsKey)
        #expect(ProviderError.kindConcernsKey("keychain_error"))
    }

    @Test("A last line cut off after the stop reason arrived still finishes the reply")
    func truncatedLastLine() async throws {
        let body = SSE.start() + SSE.text("Done.") + SSE.delta("end_turn", output: 3)
            + "event: message_stop\ndata: {\"type\":\"message_st"
        let provider = AnthropicProvider(transport: FakeTransport(body: body),
                                         secrets: InMemorySecretStore([AnthropicProvider.keyAccount: "k"]))
        let events = try await collect(provider.stream(request))
        #expect(events.last == .finished(.endTurn, TokenUsage(input: 12, output: 3)))
    }

    @Test("Without a key nothing is sent")
    func missingKey() async {
        let transport = FakeTransport(body: SSE.reply("x"))
        let provider = AnthropicProvider(transport: transport, secrets: InMemorySecretStore())
        await #expect(throws: ProviderError.missingKey) { try await collect(provider.stream(request)) }
        #expect(transport.requests.isEmpty)
    }

    @Test("A refused request surfaces the provider's error")
    func httpError() async {
        let transport = FakeTransport(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        let provider = AnthropicProvider(transport: transport, secrets: InMemorySecretStore([AnthropicProvider.keyAccount: "k"]))
        await #expect(throws: ProviderError.http(status: 401, kind: "authentication_error", message: "invalid x-api-key", retryAfter: nil)) {
            try await collect(provider.stream(request))
        }
    }

    @Test("Network requests are off where the app must not reach the network")
    func unavailableTransport() async {
        let provider = AnthropicProvider(transport: UnavailableTransport(),
                                         secrets: InMemorySecretStore([AnthropicProvider.keyAccount: "k"]))
        await #expect(throws: ProviderError.self) { try await collect(provider.stream(request)) }
    }

    @Test("Cancelling the consumer ends the request")
    func cancellation() async throws {
        let transport = HangingTransport()
        let provider = AnthropicProvider(transport: transport, secrets: InMemorySecretStore([AnthropicProvider.keyAccount: "k"]))
        let stream = provider.stream(request)
        let consumer = Task { for try await _ in stream {} }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        try await waitUntil { transport.terminated }
        #expect(transport.terminated)
    }
}
