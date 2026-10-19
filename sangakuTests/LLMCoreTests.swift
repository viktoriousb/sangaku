import Foundation
import Testing
@testable import sangaku

@Suite("Model catalog")
struct ModelCatalogTests {
    @Test("Opus 5.5 is priced per million tokens, with cache writes at 1.25× input")
    func opusPrices() throws {
        let opus = ModelResolution.known(ModelCatalog.claudeOpus55)
        let million = 1_000_000
        #expect(ModelCatalog.cost(TokenUsage(input: million), opus) == 4)
        #expect(ModelCatalog.cost(TokenUsage(cacheWrite: million), opus) == 5)
        #expect(try #require(ModelCatalog.cost(TokenUsage(cacheRead: million), opus)) == 0.2)
        #expect(ModelCatalog.cost(TokenUsage(output: million), opus) == 20)
        #expect(ModelCatalog.claudeOpus55.contextWindow == 1_000_000)
    }

    @Test("An unknown model stays unknown: no price, never a cost of 0")
    func unknownModel() {
        let resolution = ModelCatalog.standard.resolve("prover-b")
        #expect(resolution == .unknown("prover-b"))
        #expect(resolution.info == nil)
        #expect(ModelCatalog.cost(TokenUsage(input: 500, output: 500), resolution) == nil)
        #expect(ModelCatalog.standard.resolve("claude-opus-5-5").info == ModelCatalog.claudeOpus55)
    }

    @Test func defaultModelForAnthropic() {
        #expect(ModelCatalog.standard.defaultModel(for: ProviderID.anthropic)?.id == "claude-opus-5-5")
        #expect(ModelCatalog.standard.defaultModel(for: "nobody") == nil)
    }
}

@Suite("Token estimator")
struct TokenEstimatorTests {
    @Test("Longer text never estimates fewer tokens")
    func monotonic() {
        let estimator = TokenEstimator()
        var previous = 0
        for length in stride(from: 0, through: 400, by: 7) {
            let tokens = estimator.tokens(String(repeating: "a b ", count: length))
            #expect(tokens >= previous)
            previous = tokens
        }
    }

    @Test("LaTeX markup counts heavier than prose of the same length")
    func latexIsHeavier() {
        let estimator = TokenEstimator()
        let latex = #"$\frac{a_1}{b^2} \equiv \{x\}$"#
        let prose = String(repeating: "x", count: latex.utf8.count)
        #expect(estimator.tokens(latex) > estimator.tokens(prose))
        #expect(estimator.tokens("") == 0)
    }

    @Test("Calibration takes the median ratio and is clamped")
    func calibration() {
        #expect(TokenCalibration(samples: [(100, 150), (100, 300), (100, 10)]).ratio == 1.5)
        #expect(TokenCalibration(samples: [(100, 1_000), (100, 1_000)]).ratio == 2)
        #expect(TokenCalibration(samples: [(100, 1), (100, 1)]).ratio == 0.5)
        #expect(TokenCalibration(samples: []).ratio == 1)
        #expect(TokenCalibration(samples: [(0, 100)]).ratio == 1)
        #expect(TokenCalibration(ratio: 1.5).apply(100) == 150)
    }
}

@Suite("Role prompts")
struct PromptLibraryTests {
    @Test("The prover prompt is bundled and carries a version")
    func bundledProver() throws {
        let prompt = try #require(PromptLibrary.bundled.prompt(for: .prover))
        #expect(prompt.versionTag == "prover@1")
        #expect(prompt.text.contains("$...$"))
        #expect(prompt.text.contains("Never claim to have run code"))
    }

    @Test("A prompt file needs a version line and a separator")
    func parsing() {
        #expect(PromptLibrary.parse("version: 3\r\n---\r\nHello", role: .referee)?.versionTag == "referee@3")
        #expect(PromptLibrary.parse("Hello", role: .prover) == nil)
        #expect(PromptLibrary.parse("version: 1\nHello\nWorld", role: .prover) == nil)
        #expect(PromptLibrary.parse("version: 1\n---\n   ", role: .prover) == nil)
        #expect(PromptLibrary(source: { _ in nil }).prompt(for: .prover) == nil)
    }
}

@Suite("Message outcome")
struct MessageOutcomeTests {
    private func resolve(streaming: Bool = false, interrupted: Bool = false, request: Bool = true, finished: Bool = true,
                         stop: String? = nil, error: String? = nil) -> MessageOutcome {
        MessageOutcome.resolve(isStreaming: streaming, interrupted: interrupted, hasRequest: request, finished: finished,
                               stopReason: stop, stopCategory: "cyber", errorKind: error, errorMessage: error)
    }

    @Test("Precedence: streaming, declined, failed, interrupted, cut off, complete")
    func precedence() {
        #expect(resolve(streaming: true, stop: "refusal", error: "x") == .streaming)
        #expect(resolve(stop: "refusal", error: "x") == .declined(category: "cyber"))
        #expect(resolve(interrupted: true, error: "overloaded_error") == .failed(kind: "overloaded_error", message: "overloaded_error"))
        #expect(resolve(interrupted: true, stop: "max_tokens") == .interrupted)
        #expect(resolve(stop: "max_tokens") == .cutOff)
        #expect(resolve(stop: "end_turn") == .complete)
        #expect(resolve(request: false, finished: false) == .complete)
    }

    @Test("Only a stop reason known to mean finished reads as complete")
    func unknownStopReasons() {
        #expect(resolve(stop: "model_context_window_exceeded") == .cutOff)
        #expect(resolve(stop: "pause_turn") == .endedEarly(reason: "pause_turn"))
        #expect(resolve(stop: "unknown") == .endedEarly(reason: "unknown"))
        #expect(resolve(stop: "stop_sequence") == .complete)
        #expect(resolve(stop: LocalStopReason.orphaned.rawValue) == .interrupted)
        #expect(resolve(stop: LocalStopReason.appQuit.rawValue) == .interrupted)
        #expect(MessageOutcome.endedEarly(reason: "x").isPartial)
    }

    @Test("A request that never finished reads as interrupted, never as complete")
    func unfinishedIsInterrupted() {
        #expect(resolve(finished: false) == .interrupted)
        #expect(MessageOutcome.interrupted.isPartial)
        #expect(MessageOutcome.cutOff.isPartial)
        #expect(!MessageOutcome.complete.isPartial)
    }
}

@Suite("Streaming tail", .serialized)
struct StreamingTailTests {
    @Test("Math that is still arriving is held back as plain pending text")
    func splitsUnterminatedTail() {
        #expect(StreamingTail.split("Let $x").closed == "Let ")
        #expect(StreamingTail.split("Let $x").pending == "$x")
        #expect(StreamingTail.split("Let $x$ be $$y").pending == "$$y")
        #expect(StreamingTail.split("Let $x$ be").pending == "")
        #expect(StreamingTail.split(#"Cost \$5 and \(a"#).closed == #"Cost \$5 and "#)
    }

    @Test("A finished reply with a missing delimiter still shows a source chip (invariant 16)")
    func finishedTextStillWarns() {
        let fixture = PreviewFixtures.make()
        let renderer = fixture.state.renderer
        let text = #"Then $n_p \equiv 1 \pmod{p}$ and $q"#
        let (closed, _) = StreamingTail.split(text)
        #expect(MathTextComposer.compose(closed, renderer: renderer, context: fixture.mathContext).problems.isEmpty)
        #expect(!MathTextComposer.compose(text, renderer: renderer, context: fixture.mathContext).problems.isEmpty)
    }
}
