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

extension Statement {
    /// Records a Lean check of this statement as the service would after reading its own axiom line, without running
    /// Lean: the only way a test gives a statement a result that can count (invariant 12).
    @discardableResult
    func recordLeanCheck(_ source: LeanSource, axioms: [String] = ["propext"], messages: [LeanMessage] = [],
                         at date: Date = Date(timeIntervalSinceReferenceDate: 800_100_000)) -> LeanResult {
        let result = leanResult ?? LeanResult()
        result.record(.fixture(statementID: stableID, source: source, axioms: axioms, messages: messages),
                      module: LeanModulePlan([(stableID, source)]).digest, environment: LeanFixtureCode.environment,
                      checkedBy: nil, sourceAuthor: nil, draftMessageID: nil, duration: 1, at: date)
        leanResult = result
        return result
    }

    /// A person's fidelity review of the current Lean statement on the current wording.
    func confirmLean(by person: PersonID, verdict: FidelityVerdict = .matches,
                     at date: Date = Date(timeIntervalSinceReferenceDate: 800_100_060)) {
        let review = FidelityReview(reviewer: person, leanStatementSource: leanResult?.leanStatementSource ?? "",
                                    verdict: verdict)
        review.informalWording = statementLaTeX
        review.createdAt = date
        fidelityReviews = (fidelityReviews ?? []) + [review]
    }
}

extension LeanSource {
    /// `theorem main : True := trivial`, the smallest statement a test needs.
    static let trivial = LeanSource(statementPart: "theorem main : True", proofPart: ":= trivial")
}

/// A tool executor driven by the test: records each job, and answers with the next scripted report, or holds the job
/// until it is released or stopped.
nonisolated final class ScriptedExecutor: ToolExecuting {
    private struct State {
        var jobs: [SandboxJob] = []
        var reports: [RunReport] = []
        var held: [UUID: CheckedContinuation<Void, Never>] = [:]
        var holds = false
        var killedAll = 0
    }

    private let state = Mutex(State())

    var jobs: [SandboxJob] { state.withLock { $0.jobs } }
    var killedAll: Int { state.withLock { $0.killedAll } }

    /// Reports to answer with, in order; when they run out, a clean exit with no output.
    func script(_ reports: RunReport...) { state.withLock { $0.reports.append(contentsOf: reports) } }

    /// Jobs wait until `release()` or until stopped.
    func hold() { state.withLock { $0.holds = true } }

    func release() {
        let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.holds = false
            defer { state.held = [:] }
            return Array(state.held.values)
        }
        held.forEach { $0.resume() }
    }

    func killAll() { state.withLock { $0.killedAll += 1 } }

    @concurrent func execute(_ job: SandboxJob, onOutput: (@Sendable (String) -> Void)?) async -> RunReport {
        let holds = state.withLock { state -> Bool in
            state.jobs.append(job)
            return state.holds
        }
        if holds {
            // Stopping one held job releases that job only.
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeNow = state.withLock { state -> Bool in
                        if Task.isCancelled { return true }
                        state.held[id] = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                state.withLock { $0.held.removeValue(forKey: id) }?.resume()
            }
            if Task.isCancelled {
                return RunReport(end: .stopped, stdout: CappedText(text: ""), stderr: CappedText(text: ""),
                                 startedAt: Date(timeIntervalSinceReferenceDate: 0), seconds: 0)
            }
        }
        let next = state.withLock { state -> RunReport? in state.reports.isEmpty ? nil : state.reports.removeFirst() }
        return next ?? RunReport(end: .exited(0), stdout: CappedText(text: ""), stderr: CappedText(text: ""),
                                 startedAt: Date(timeIntervalSinceReferenceDate: 0), seconds: 0)
    }
}

extension RunReport {
    /// A finished run with this output, for scripting.
    static func exited(_ code: Int32 = 0, stdout: String = "", stderr: String = "") -> RunReport {
        RunReport(end: .exited(code), stdout: CappedText(text: stdout), stderr: CappedText(text: stderr),
                  startedAt: Date(timeIntervalSinceReferenceDate: 800_200_000), seconds: 3)
    }
}

/// Answers each request by its host, from a table, and records every URL asked for.
nonisolated final class RoutedTransport: HTTPTransport {
    nonisolated enum Reply: Sendable {
        case body(Int, String)
        case error(URLError.Code)
        /// Answers after a pause, or fails at once if the request is cancelled first.
        case slow(Duration, Int, String)
    }

    private let routes: [String: Reply]
    private let asked = Mutex<[URL]>([])

    init(_ routes: [String: Reply]) {
        self.routes = routes
    }

    var urls: [URL] { asked.withLock { $0 } }

    @concurrent func open(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let url = try #require(request.url)
        asked.withLock { $0.append(url) }
        var reply = routes[url.host() ?? ""]
        if case .slow(let pause, let status, let text)? = reply {
            try await Task.sleep(for: pause)
            reply = .body(status, text)
        }
        switch reply {
        case .slow?:
            throw URLError(.unknown)
        case .body(let status, let text)?:
            let chunks = AsyncThrowingStream<Data, any Error> { continuation in
                continuation.yield(Data(text.utf8))
                continuation.finish()
            }
            return HTTPStreamResponse(status: status, headers: [:], chunks: chunks)
        case .error(let code)?:
            throw URLError(code)
        case nil:
            throw URLError(.cannotFindHost)
        }
    }
}
