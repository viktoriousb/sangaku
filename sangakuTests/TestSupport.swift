import Foundation
import Synchronization
import Testing
@testable import sangaku

/// Answers every request with a canned status and body, delivered in the given chunks, and records requests.
nonisolated final class FakeTransport: HTTPTransport {
    let status: Int
    let headers: [String: String]
    let chunks: [Data]
    private let recorded = Mutex<[URLRequest]>([])

    init(status: Int = 200, headers: [String: String] = [:], body: String, chunkSize: Int = 64) {
        self.status = status
        self.headers = headers
        let bytes = Array(body.utf8)
        chunks = stride(from: 0, to: bytes.count, by: chunkSize).map { Data(bytes[$0..<min($0 + chunkSize, bytes.count)]) }
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }

    @concurrent func open(_ request: URLRequest) async throws -> HTTPStreamResponse {
        recorded.withLock { $0.append(request) }
        let chunks = chunks
        return HTTPStreamResponse(status: status, headers: headers, chunks: AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        })
    }
}

/// Opens a stream that never sends anything, and notes when its consumer goes away.
nonisolated final class HangingTransport: HTTPTransport {
    private let ended = Mutex(false)
    var terminated: Bool { ended.withLock { $0 } }

    @concurrent func open(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let chunks = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.onTermination = { [weak self] _ in self?.ended.withLock { $0 = true } }
        }
        return HTTPStreamResponse(status: 200, headers: [:], chunks: chunks)
    }
}

/// A provider the test drives event by event.
nonisolated final class ScriptedProvider: ModelProvider {
    let id = ProviderID.anthropic
    let displayName = "Anthropic"

    private struct State {
        var requests: [ProviderRequest] = []
        var continuations: [AsyncThrowingStream<ProviderEvent, any Error>.Continuation] = []
        var terminated = 0
    }
    private let state = Mutex(State())

    var requests: [ProviderRequest] { state.withLock { $0.requests } }
    var terminatedCount: Int { state.withLock { $0.terminated } }

    func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream()
        continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.terminated += 1 } }
        state.withLock {
            $0.requests.append(request)
            $0.continuations.append(continuation)
        }
        return stream
    }

    func send(_ events: ProviderEvent...) {
        let continuation = state.withLock { $0.continuations.last }
        for event in events { continuation?.yield(event) }
    }

    func fail(_ error: any Error) {
        state.withLock { $0.continuations.last }?.finish(throwing: error)
    }

    func end() {
        state.withLock { $0.continuations.last }?.finish()
    }

    /// The same, for the request at `index` in the order the requests were made, so concurrent requests can be
    /// driven one by one.
    func send(to index: Int, _ events: ProviderEvent...) {
        let continuation = state.withLock { $0.continuations.indices.contains(index) ? $0.continuations[index] : nil }
        for event in events { continuation?.yield(event) }
    }

    /// Streams `text` to request `index` and finishes it normally.
    func reply(to index: Int, _ text: String, usage: TokenUsage = TokenUsage(input: 40, output: 30)) {
        send(to: index, .started(answeredModel: "claude-opus-5-5", usage: TokenUsage(input: usage.input)), .text(text),
             .finished(.endTurn, usage))
    }

    func fail(at index: Int, _ error: any Error) {
        state.withLock { $0.continuations.indices.contains(index) ? $0.continuations[index] : nil }?.finish(throwing: error)
    }
}

/// A keychain that refuses every read, as when a person denies the prompt.
nonisolated struct FailingSecretStore: SecretStore {
    @concurrent func read(_ account: String) async throws -> String? {
        throw SecretStoreError(status: -25308, message: "User interaction is not allowed.")
    }

    @concurrent func exists(_ account: String) async throws -> Bool { true }
    @concurrent func write(_ secret: String, account: String) async throws {}
    @concurrent func delete(_ account: String) async throws {}
}

/// Counts every call, to show what does and does not touch the store.
nonisolated final class SpySecretStore: SecretStore {
    private let inner = InMemorySecretStore()
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }

    @concurrent func read(_ account: String) async throws -> String? {
        count.withLock { $0 += 1 }
        return try await inner.read(account)
    }

    @concurrent func exists(_ account: String) async throws -> Bool {
        count.withLock { $0 += 1 }
        return try await inner.exists(account)
    }

    @concurrent func write(_ secret: String, account: String) async throws {
        count.withLock { $0 += 1 }
        try await inner.write(secret, account: account)
    }

    @concurrent func delete(_ account: String) async throws {
        count.withLock { $0 += 1 }
        try await inner.delete(account)
    }
}

/// Server-sent events in the Anthropic wire format.
enum SSE {
    static func event(_ name: String, _ json: String) -> String { "event: \(name)\ndata: \(json)\n\n" }

    static func quoted(_ text: String) -> String {
        (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    static func start(model: String = "claude-opus-5-5", input: Int = 12, cacheWrite: Int = 0, cacheRead: Int = 0) -> String {
        event("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead),"output_tokens":1}}}"#)
    }

    static let thinking = event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)
        + event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"x"}}"#)
        + event("content_block_stop", #"{"type":"content_block_stop","index":0}"#)

    static func text(_ pieces: String...) -> String {
        event("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#)
            + pieces.map {
                event("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":\#(quoted($0))}}"#)
            }.joined()
            + event("content_block_stop", #"{"type":"content_block_stop","index":1}"#)
    }

    static let ping = event("ping", #"{"type":"ping"}"#)

    static func delta(_ stopReason: String, output: Int, category: String? = nil) -> String {
        let details = category.map { #","stop_details":{"type":"refusal","category":"\#($0)"}"# } ?? ""
        return event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"\#(details)},"usage":{"output_tokens":\#(output)}}"#)
    }

    static let stop = event("message_stop", #"{"type":"message_stop"}"#)

    static func reply(_ text: String, input: Int = 12, cacheRead: Int = 0, output: Int = 7) -> String {
        start(input: input, cacheRead: cacheRead) + thinking + ping + Self.text(text) + delta("end_turn", output: output) + stop
    }
}

/// Polls until `condition` holds, so a test can wait for events to reach the main actor.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool,
               sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting for a condition", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// SplitMix64: a small seeded generator, so property tests are reproducible.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What is running, as a test decides it.
final class TestActivity: BranchActivity {
    var liveMessageIDs: Set<UUID> = []
    var streamingBranchIDs: Set<UUID> = []
}

extension PreviewFixtures.Handles {
    /// A branch manager on the example whose running requests the test decides.
    func branchManager(activity: TestActivity, now: @escaping () -> Date = { .now }) -> BranchManager {
        BranchManager(context: state.container.mainContext, saves: state.saves, problems: state.problems,
                      statements: state.graph, activity: activity, now: now)
    }

    /// The offers for a branch as the menus read them.
    func offers(for branch: Branch, activity: TestActivity, hidesAuthors: Bool = false) -> BranchOffers {
        BranchOffers(branch, mainBranchID: problem.mainBranchID, streaming: activity.streamingBranchIDs,
                     live: activity.liveMessageIDs, hidesAuthors: hidesAuthors)
    }
}
