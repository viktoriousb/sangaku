#if DEBUG
import Foundation
import Synchronization

/// Streams canned answers in the provider's wire format, so the fixture can show streaming, fan-outs, the referee,
/// Stop and View context without a network or a key (`-SangakuFixture -SangakuDemoReplies`). A request that asks
/// for an attempt gets one, alternately sound and flawed; a request for verdicts gets them; anything else gets
/// prose. Debug builds only.
nonisolated final class DemoTransport: HTTPTransport {
    let pause: Duration
    private let attempts = Mutex(0)

    init(pause: Duration = .milliseconds(45)) {
        self.pause = pause
    }

    static let answer = #"""
    This reply is a demonstration streamed by the fixture, not by a model. Step 1 (establishes: Sylow counts; confidence: standard). By Sylow's theorems $n_p \in \{1, q\}$ with $n_p \equiv 1 \pmod{p}$, and $n_q \in \{1, p, p^2\}$ with $n_q \equiv 1 \pmod{q}$. Step 2 (establishes: q > p; confidence: routine). If neither Sylow subgroup is normal, then $n_p = q$, so $$q \equiv 1 \pmod{p},$$ and in particular $q > p$. Step 3 (establishes: the order 12 case; confidence: delicate). The remaining case forces $(p, q) = (2, 3)$ and $|G| = 12$, which needs a separate count of elements of order $3$.
    """#

    static let soundAttempt = DemoOutput.attempt(
        overview: "A demonstration attempt streamed by the fixture, not by a model. Count Sylow subgroups and resolve the one case they leave.",
        steps: [
            ("Sylow counts", .standard, #"$n_p \in \{1, q\}$ with $n_p \equiv 1 \pmod{p}$, and $n_q \in \{1, p, p^2\}$ with $n_q \equiv 1 \pmod{q}$."#),
            ("q > p", .routine, #"If neither Sylow subgroup is normal, then $n_p = q$, so $q \equiv 1 \pmod{p}$ and $q > p$."#),
            ("n_q = p^2", .routine, #"$n_q = p$ would need $p \equiv 1 \pmod{q}$, impossible since $p < q$. Hence $n_q = p^2$."#),
            ("Resolve q | p + 1", .delicate, #"Then $q \mid (p - 1)(p + 1)$ and $q \nmid p - 1$, so $q = p + 1$, which forces $(p, q) = (2, 3)$."#),
            ("Order 12 case", .routine, #"With $|G| = 12$ and $n_3 = 4$ there are $8$ elements of order $3$, so the Sylow $2$-subgroup is unique and normal."#),
        ])

    static let flawedAttempt = DemoOutput.attempt(
        overview: "A demonstration attempt streamed by the fixture, not by a model, with a deliberate gap at step 4.",
        steps: [
            ("Sylow counts", .standard, #"By Sylow, $n_p \mid q$ with $n_p \equiv 1 \pmod{p}$, and $n_q \mid p^2$ with $n_q \equiv 1 \pmod{q}$."#),
            ("q > p", .routine, #"If no Sylow subgroup is normal, $n_p = q$, so $p \mid q - 1$ and $q > p$."#),
            ("n_q = p^2", .routine, #"Since $1 < p < q$, $n_q \neq p$, so $n_q = p^2$ and $q \mid p + 1$."#),
            ("Resolve q | p + 1", .routine, #"Since $q > p$, $q$ cannot divide $p + 1$, a contradiction."#),
        ])

    @concurrent func open(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let promptBytes = request.httpBody?.count ?? 0
        let text = answer(for: request.httpBody ?? Data())
        let events = Self.events(text, inputTokens: max(1, promptBytes / 4))
        let pause = pause
        let chunks = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                do {
                    for event in events {
                        try await Task.sleep(for: pause)
                        continuation.yield(Data(event.utf8))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(status: 200, headers: [:], chunks: chunks)
    }

    /// What the request asked for, read from its output format's schema.
    private func answer(for body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let config = object["output_config"] as? [String: Any],
              let format = config["format"] as? [String: Any],
              let schema = format["schema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else { return Self.answer }
        if properties["steps"] != nil {
            let index = attempts.withLock { count in
                defer { count += 1 }
                return count
            }
            return index.isMultiple(of: 2) ? Self.soundAttempt : Self.flawedAttempt
        }
        let verdicts = (properties["verdicts"] as? [String: Any])?["items"] as? [String: Any]
        let attempt = ((verdicts?["properties"] as? [String: Any])?["attempt"] as? [String: Any])
        let letters = attempt?["enum"] as? [String] ?? []
        return DemoOutput.referee(
            summary: "A demonstration verdict from the fixture, not from a model. "
                + (letters.count > 1 ? "\(letters[0])'s attempt is complete; the others stop at a false step." : "The attempt is complete."),
            verdicts: letters.enumerated().map { index, letter in
                index == 0
                    ? (letter, .complete, [], "Each step follows; the delicate one is the case $q = p + 1$.")
                    : (letter, .gap, [4], #"Step 4 is false: $q > p$ allows $q = p + 1$, as at $(p, q) = (2, 3)$."#)
            })
    }

    static func events(_ text: String, inputTokens: Int) -> [String] {
        func event(_ name: String, _ json: String) -> String { "event: \(name)\ndata: \(json)\n\n" }
        func quoted(_ text: String) -> String {
            String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        var events = [
            event("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":\#(inputTokens),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#),
            event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            event("ping", #"{"type":"ping"}"#),
            event("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            event("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
        ]
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(14)
            rest = rest.dropFirst(piece.count)
            events.append(event("content_block_delta",
                                #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":\#(quoted(String(piece)))}}"#))
        }
        events += [
            event("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":\#(text.count / 3)}}"#),
            event("message_stop", #"{"type":"message_stop"}"#),
        ]
        return events
    }
}

/// Output in the structured formats, as the demo and the fixture write it. Encoding doubles every LaTeX
/// backslash, as the prompts ask models to do.
nonisolated enum DemoOutput {
    private struct Step: Encodable {
        let establishes: String
        let confidence: String
        let text: String
    }

    private struct Attempt: Encodable {
        let overview: String
        let steps: [Step]
    }

    private struct Verdict: Encodable {
        let attempt: String
        let outcome: String
        let gapSteps: [Int]
        let rationale: String

        enum CodingKeys: String, CodingKey {
            case attempt, outcome, rationale
            case gapSteps = "gap_steps"
        }
    }

    private struct Report: Encodable {
        let verdicts: [Verdict]
        let summary: String
    }

    static func attempt(overview: String, steps: [(establishes: String, confidence: Confidence, text: String)]) -> String {
        encode(Attempt(overview: overview, steps: steps.map {
            Step(establishes: $0.establishes, confidence: $0.confidence.rawValue, text: $0.text)
        }))
    }

    static func referee(summary: String,
                        verdicts: [(letter: String, outcome: RefereeOutcome, gapSteps: [Int], rationale: String)]) -> String {
        encode(Report(verdicts: verdicts.map {
            Verdict(attempt: $0.letter, outcome: $0.outcome.rawValue, gapSteps: $0.gapSteps, rationale: $0.rationale)
        }, summary: summary))
    }

    private static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
#endif
