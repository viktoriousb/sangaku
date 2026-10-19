import Foundation
import Testing
@testable import sangaku

@Suite("Attempt parsing")
struct AttemptParsingTests {
    private func attempt(_ steps: String, overview: String = "An overview.") -> String {
        #"{"overview":"\#(overview)","steps":[\#(steps)]}"#
    }

    private func step(_ text: String, establishes: String = "a claim", confidence: String = "routine") -> String {
        #"{"establishes":"\#(establishes)","confidence":"\#(confidence)","text":"\#(text)"}"#
    }

    @Test("A whole attempt reads cleanly, with LaTeX intact")
    func clean() throws {
        guard case .clean(let parsed) = AttemptParser.parse(DemoTransport.soundAttempt, lenient: false) else {
            Issue.record("expected a clean parse")
            return
        }
        #expect(parsed.steps.count == 5)
        #expect(parsed.steps[0].text.contains(#"\pmod{p}"#), "doubled backslashes decode to one")
        #expect(parsed.steps[3].confidence == .delicate)
        #expect(parsed.overview.hasPrefix("A demonstration attempt"))
    }

    @Test("Invariant 16: a single backslash that JSON turns into a control character is refused, never kept as text",
          arguments: [#"\theta"#, #"\frac{a}{b}"#, #"\beta"#, #"\rho"#, #"\neq"#, #"\nmid"#, #"\tau"#, #"\binom{n}{k}"#])
    func singleBackslashRefused(command: String) {
        let raw = attempt(step("$x " + command + " y$"))
        #expect(AttemptParser.parse(raw, lenient: false) == .unstructured)
        #expect(AttemptParser.parse(raw, lenient: true) == .partial(ParsedAttempt(overview: "An overview.", steps: [])),
                "read leniently, the unreadable step is left out, never turned into text")
    }

    @Test("A backslash that is not a JSON escape fails to decode at all")
    func invalidEscape() {
        #expect(AttemptParser.parse(attempt(step(#"$\alpha$"#)), lenient: false) == .unstructured)
    }

    @Test("Doubled backslashes survive as LaTeX")
    func doubled() {
        guard case .clean(let parsed) = AttemptParser.parse(attempt(step(#"$\\theta \\neq \\frac{1}{2}$"#)), lenient: false) else {
            Issue.record("expected a clean parse")
            return
        }
        #expect(parsed.steps.first?.text == #"$\theta \neq \frac{1}{2}$"#)
    }

    @Test("An unknown confidence label or a missing field is not a clean attempt")
    func offSchema() {
        #expect(AttemptParser.parse(attempt(step("x", confidence: "certain")), lenient: false) == .unstructured)
        #expect(AttemptParser.parse(#"{"steps":[]}"#, lenient: false) == .unstructured)
        #expect(AttemptParser.parse("I cannot help with that.", lenient: true) == .unstructured)
    }

    @Test("An attempt with no steps but an overview is read: the model said why it gave none")
    func noSteps() {
        #expect(AttemptParser.parse(attempt("", overview: "The statement is false for p = 2."), lenient: false)
                == .clean(ParsedAttempt(overview: "The statement is false for p = 2.", steps: [])))
    }

    @Test("Cut at every point, an attempt reads as a prefix of its steps, and only the whole text reads cleanly")
    func truncatedEverywhere() throws {
        let full = DemoTransport.soundAttempt
        guard case .clean(let whole) = AttemptParser.parse(full, lenient: false) else {
            Issue.record("expected a clean parse")
            return
        }
        let bytes = Array(full.utf8)
        for cut in 0..<bytes.count {
            let prefix = String(decoding: bytes[0..<cut], as: UTF8.self)
            #expect(AttemptParser.parse(prefix, lenient: false) == .unstructured, "a finished attempt is read whole or not at all")
            switch AttemptParser.parse(prefix, lenient: true) {
            case .clean:
                Issue.record("a cut attempt read as clean at \(cut)")
            case .partial(let parsed):
                #expect(Array(whole.steps.prefix(parsed.steps.count)) == parsed.steps, "steps are a prefix at \(cut)")
                #expect(parsed.overview.isEmpty || parsed.overview == whole.overview)
            case .unstructured:
                break
            }
            #expect(AttemptParser.progress(prefix).count <= whole.steps.count)
        }
    }

    @Test("Reading what arrived stops at the first step that cannot be read, so it never leaves a hole")
    func lenientStopsAtBadStep() {
        let raw = attempt([step("one"), step(#"$\theta$"#), step("three")].joined(separator: ","))
        #expect(AttemptParser.parse(raw, lenient: true) == .partial(ParsedAttempt(
            overview: "An overview.", steps: [ParsedStep(establishes: "a claim", confidence: .routine, text: "one")])))
    }
}

@Suite("Referee verdicts")
struct RefereeMappingTests {
    private let a = AttemptRef(messageID: UUID(), letter: "A", stepCount: 6, partial: false)
    private let b = AttemptRef(messageID: UUID(), letter: "B", stepCount: 5, partial: true)

    private func report(_ entries: [(String, String, [Int])]) -> RefereeReport {
        RefereeReport(verdicts: entries.map { RefereeReport.Entry(attempt: $0.0, outcome: $0.1, gapSteps: $0.2, rationale: "Because.") },
                      summary: "Summary.")
    }

    @Test("The demo's report reads, with its letters and steps")
    func parses() throws {
        let raw = DemoOutput.referee(summary: "Both judged.", verdicts: [("A", .complete, [], "Fine."), ("B", .gap, [4], #"Step 4 needs $q \nmid p - 1$."#)])
        let parsed = try #require(RefereeParser.parse(raw))
        #expect(parsed.summary == "Both judged.")
        #expect(parsed.verdicts.map(\.attempt) == ["A", "B"])
        #expect(parsed.verdicts[1].gapSteps == [4])
        #expect(parsed.verdicts[1].rationale.contains(#"\nmid"#))
        #expect(RefereeParser.parse(String(raw.dropLast(3))) == nil, "a referee that stopped early gives no verdicts")
    }

    @Test("Invariant 16: a referee's single backslash turned into a control character gives no verdicts at all")
    func refereeControlCharacters() {
        let raw = #"{"verdicts":[{"attempt":"A","rationale":"Step 2 uses $\theta$.","gap_steps":[2],"outcome":"gap"}],"summary":"x"}"#
        #expect(RefereeParser.parse(raw) == nil)
    }

    @Test("Fail closed: an attempt with nothing in it is never complete, whatever the referee says")
    func nothingToJudge() {
        let empty = AttemptRef(messageID: UUID(), letter: "C", stepCount: 0, partial: false, hasContent: false)
        let drafts = VerdictMapper.map(report([("C", "complete", [])]), attempts: [empty])
        #expect(drafts.map(\.outcome) == [.gap])
    }

    @Test("Fail closed: an attempt not judged gets no verdict, never a complete one")
    func unjudged() {
        let drafts = VerdictMapper.map(report([("A", "complete", [])]), attempts: [a, b])
        #expect(drafts.map(\.attemptMessageID) == [a.messageID])
    }

    @Test("Fail closed: complete with gaps listed is a gap; an unknown outcome is a gap")
    func strictOutcomes() {
        let drafts = VerdictMapper.map(report([("A", "complete", [3]), ("B", "mostly fine", [])]), attempts: [a, b])
        #expect(drafts.map(\.outcome) == [.gap, .gap])
        #expect(drafts[0].gapStepIndices == [3])
    }

    @Test("Several entries for one attempt merge into the least trusting; unknown letters and steps out of range are dropped")
    func mergesAndFilters() {
        let drafts = VerdictMapper.map(report([("a ", "complete", []), ("A", "gap", [2, 9, 0]), ("Z", "complete", [])]),
                                       attempts: [a, b])
        #expect(drafts.count == 1)
        #expect(drafts[0].outcome == .gap)
        #expect(drafts[0].gapStepIndices == [2], "6 steps: 9 and 0 name none of them")
        #expect(drafts[0].rationale == "Because.\n\nBecause.")
    }

    @Test("Invariant 4: a verdict on an attempt that reached the referee partial says so")
    func partial() {
        let drafts = VerdictMapper.map(report([("A", "complete", []), ("B", "complete", [])]), attempts: [a, b])
        #expect(drafts.map(\.sawPartialAttempt) == [false, true])
    }
}

@Suite("Output formats on the wire")
struct OutputFormatTests {
    /// Every object in a schema is closed and requires all its properties, as the provider demands.
    private func lint(_ value: Any, path: String = "$") {
        if let object = value as? [String: Any] {
            if object["type"] as? String == "object" {
                #expect(object["additionalProperties"] as? Bool == false, "\(path) is not closed")
                let properties = (object["properties"] as? [String: Any]) ?? [:]
                #expect(Set((object["required"] as? [String]) ?? []) == Set(properties.keys), "\(path) leaves a property optional")
            }
            for forbidden in ["minimum", "maximum", "minLength", "maxLength", "$ref"] {
                #expect(object[forbidden] == nil, "\(path) uses \(forbidden)")
            }
            for (key, child) in object { lint(child, path: path + "." + key) }
        } else if let array = value as? [Any] {
            for child in array { lint(child, path: path + "[]") }
        }
    }

    @Test("Both schemas are valid JSON, closed, with every property required")
    func schemasAreClosed() throws {
        for format in [OutputFormat.attempt, .refereeVerdicts(letters: ["A", "B"])] {
            let schema = try JSONSerialization.jsonObject(with: Data(format.schemaJSON.utf8))
            lint(schema)
        }
        let referee = try #require(try JSONSerialization.jsonObject(
            with: Data(OutputFormat.refereeVerdicts(letters: ["A", "C"]).schemaJSON.utf8)) as? [String: Any])
        let verdicts = (referee["properties"] as? [String: Any])?["verdicts"] as? [String: Any]
        let attempt = ((verdicts?["items"] as? [String: Any])?["properties"] as? [String: Any])?["attempt"] as? [String: Any]
        #expect(attempt?["enum"] as? [String] == ["A", "C"], "only the attempts' letters can be named")
    }

    @Test("The schema reaches the wire unchanged, beside the effort; a prose request carries none")
    func wireBody() throws {
        let fixture = PreviewFixtures.make()
        let snapshot = ProblemSnapshot.make(problem: fixture.problem, branch: fixture.mainBranch,
                                            notation: fixture.state.problems.notation(for: fixture.problem),
                                            people: [fixture.you, fixture.mk], liveMessageIDs: [])
        let prompt = try #require(PromptLibrary.bundled.prompt(for: .prover, structured: true))
        let built = try ContextBuilder().build(ContextInput(
            snapshot: snapshot, providerID: ProviderID.anthropic, purpose: .reply(slot: fixture.slotA.slotID, fanOut: nil),
            rolePrompt: prompt, pending: "Prove it.", inputBudget: nil, format: .attempt))
        let request = ProviderRequest(built, modelID: "claude-opus-5-5", effort: .high, maxOutputTokens: 1000)
        #expect(request.format == .attempt)
        let body = try #require(try JSONSerialization.jsonObject(with: AnthropicWire.body(request)) as? [String: Any])
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "high")
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false, "the keyword is not rewritten to snake case")
        #expect(NSDictionary(dictionary: schema).isEqual(to: try #require(
            try JSONSerialization.jsonObject(with: Data(OutputFormat.attempt.schemaJSON.utf8)) as? [String: Any])))
        let wire = String(decoding: AnthropicWire.body(request), as: UTF8.self)
        #expect(wire.contains(OutputFormat.attempt.schemaJSON), "byte for byte, so its properties keep their order")
        let schemaText = OutputFormat.attempt.schemaJSON
        let order = ["\"text\"", "\"establishes\"", "\"confidence\""].compactMap { schemaText.range(of: $0)?.lowerBound }
        #expect(order.count == 3 && order == order.sorted(), "a step's text is written before its label and confidence")
        #expect(body["max_tokens"] as? Int == 1000)

        let prose = try ContextBuilder().build(ContextInput(
            snapshot: snapshot, providerID: ProviderID.anthropic, purpose: .reply(slot: fixture.slotA.slotID, fanOut: nil),
            rolePrompt: try #require(PromptLibrary.bundled.prompt(for: .prover)), pending: "Hello.", inputBudget: nil))
        let plain = try #require(try JSONSerialization.jsonObject(
            with: AnthropicWire.body(ProviderRequest(prose, modelID: "claude-opus-5-5", effort: .high, maxOutputTokens: 1000))) as? [String: Any])
        #expect((plain["output_config"] as? [String: Any])?["format"] == nil)
        #expect(built.formatTokens > 0 && prose.formatTokens == 0, "the schema counts toward the input estimate")
    }

    @Test("Role prompts: attempts and the referee have their own, with versions; prose replies keep prover@1")
    func prompts() throws {
        #expect(try #require(PromptLibrary.bundled.prompt(for: .prover)).versionTag == "prover@1")
        let attempt = try #require(PromptLibrary.bundled.prompt(for: .prover, structured: true))
        #expect(attempt.versionTag == "prover-attempt@2", "tagged by file, so it never collides with the prose prompt")
        #expect(attempt.text.contains(#"\\frac"#), "it asks for doubled backslashes")
        let referee = try #require(PromptLibrary.bundled.prompt(for: .referee, structured: true))
        #expect(referee.versionTag == "referee@1")
        #expect(referee.text.contains("never a check by a person"))
        #expect(PromptLibrary.bundled.prompt(for: .formalizer) == nil, "formalizers have no prompt yet")
    }
}
