import Foundation
import SwiftData
import Synchronization
import Testing
@testable import sangaku

@Suite("Verification: computations and refutations")
struct ComputeServiceTests {
    private let fixture = PreviewFixtures.make()
    private let executor = ScriptedExecutor()
    private let compute: ComputeService

    init() {
        var values = ToolSettings.Values()
        values.paths[.python] = "/bin/sh"
        let tools = ToolRunner(executor: executor,
                               workRoot: FileManager.default.temporaryDirectory.appending(path: "sangaku-compute-tests"))
        compute = ComputeService(context: fixture.state.container.mainContext, saves: fixture.state.saves,
                                 problems: fixture.state.problems, tools: tools,
                                 settings: ToolSettings(storage: .memory(values), locator: ToolLocator(isExecutable: { $0 == "/bin/sh" })),
                                 now: { Date(timeIntervalSinceReferenceDate: 800_400_000) })
    }

    private var context: ModelContext { fixture.state.container.mainContext }

    /// A scout's cell on the main branch, attached to Lem 3.
    private func cell(_ code: String = "print('sangaku-result: holds')", tool: EvidenceTool = .python) -> (Message, ComputeCell) {
        let message = Message(author: .model(fixture.slotA.slotID), bodyLaTeX: "A check.", kind: .compute)
        context.insert(message)
        let cell = ComputeCell(tool: tool, code: code, scope: "primes p < q < 50", claim: "q | p + 1 forces (2, 3)",
                               statementID: fixture.lemmas[2].stableID)
        message.computeCell = cell
        fixture.mainBranch.messages = (fixture.mainBranch.messages ?? []) + [message]
        return (message, cell)
    }

    @Test("Invariant 14: Run runs exactly the code shown, in the sandbox, and records the run as evidence")
    func run() async throws {
        let (message, cell) = cell()
        executor.script(.exited(0), .exited(0, stdout: "checked 105 pairs\nsangaku-result: holds\n"))
        try compute.run(cell: message.stableID, shown: TextDigest(of: cell.code))
        try await waitUntil { !(cell.runs ?? []).isEmpty }
        let job = try #require(executor.jobs.last)
        #expect(job.kind == .offline && job.files.map(\.contents) == [cell.code])
        #expect(job.arguments.prefix(3) == ["-I", "-B", "-u"])
        let evidence = try #require(cell.runs?.first)
        #expect(evidence.code == cell.code && evidence.outcome == .completed && evidence.verdict == .holds && evidence.passed)
        #expect(evidence.runByID == fixture.you.stableID && evidence.scope == "primes p < q < 50")
        #expect(evidence.statement === fixture.lemmas[2])
        #expect(compute.state(of: cell) == .ran(outcome: .completed, verdict: .holds))
    }

    @Test("A cell runs from the click: a second Run is refused, and Stop before the code runs records nothing")
    func stopBeforeRun() async throws {
        let (message, cell) = cell()
        executor.hold()
        try compute.run(cell: message.stableID, shown: TextDigest(of: cell.code))
        #expect(compute.state(of: cell) == .running, "the version probe runs first")
        #expect(throws: VerificationError.cellRunning) {
            try compute.run(cell: message.stableID, shown: TextDigest(of: cell.code))
        }
        try await waitUntil { executor.jobs.count == 1 }
        compute.stop(cell: cell.stableID)
        try await waitUntil { !compute.isRunning(cell: cell.stableID) }
        #expect(executor.jobs.count == 1, "the cell's code never ran")
        #expect((cell.runs ?? []).isEmpty && compute.lastFailure[cell.stableID] == nil)
    }

    @Test("A tool's version is kept once a probe tells it, and asked again after one that failed")
    func versions() async throws {
        let (message, cell) = cell()
        executor.script(.exited(1), .exited(0, stdout: "sangaku-result: holds\n"),
                        .exited(0, stdout: "Python 3.15.0\n"), .exited(0, stdout: "sangaku-result: holds\n"),
                        .exited(0, stdout: "sangaku-result: holds\n"))
        for count in 1...3 {
            try compute.run(cell: message.stableID, shown: TextDigest(of: cell.code))
            try await waitUntil { (cell.runs ?? []).count == count && !compute.isRunning(cell: cell.stableID) }
        }
        let versions = (cell.runs ?? []).sorted { $0.createdAt < $1.createdAt }.map(\.toolVersion)
        #expect(versions == ["", "Python 3.15.0", "Python 3.15.0"] && executor.jobs.count == 5)
    }

    @Test("How a run ended is said to VoiceOver when it ends")
    func announced() async throws {
        let said = Mutex<[String]>([])
        let tools = ToolRunner(executor: executor, workRoot: FileManager.default.temporaryDirectory.appending(path: "sangaku-say"))
        var values = ToolSettings.Values()
        values.paths[.python] = "/bin/sh"
        let speaking = ComputeService(context: context, saves: fixture.state.saves, problems: fixture.state.problems,
                                      tools: tools,
                                      settings: ToolSettings(storage: .memory(values), locator: ToolLocator(isExecutable: { $0 == "/bin/sh" })),
                                      announce: { text in said.withLock { $0.append(text) } })
        let (message, cell) = cell()
        executor.script(.exited(0), .exited(0, stdout: "sangaku-result: holds\n"))
        try speaking.run(cell: message.stableID, shown: TextDigest(of: cell.code))
        try await waitUntil { !(cell.runs ?? []).isEmpty }
        #expect(said.withLock { $0 } == ["The computation on Lem 3 has ended; its run is in the thread."])
    }

    @Test("Deleting a problem stops its computation, version probe included, and records nothing")
    func deletedMidRun() async throws {
        let executor = ScriptedExecutor()
        executor.hold()
        var values = ToolSettings.Values()
        values.paths[.python] = "/bin/sh"
        let state = AppState(storage: .inMemory, executor: executor, toolStorage: .memory(values))
        let problem = state.problems.createProblem(title: "P", statementLaTeX: "Let $|G| = p^2 q$.")
        let statement = try #require(problem.statements?.first)
        let branch = try #require(problem.mainBranch)
        let messageID = try state.compute.writeCell(on: branch, statement: statement.stableID, tool: .python,
                                                    code: "print(1)", scope: "one case", claim: "")
        let cell = try #require(state.container.mainContext.first(Message.self, stableID: messageID)?.computeCell)
        let cellID = cell.stableID
        try state.compute.run(cell: messageID, shown: TextDigest(of: cell.code))
        try await waitUntil { executor.jobs.count == 1 }
        state.problems.delete(problem)
        try await waitUntil { !state.compute.isRunning(cell: cellID) }
        #expect(executor.jobs.count == 1, "the cell's code never ran")
        #expect(state.container.mainContext.first(ComputeCell.self, stableID: cellID) == nil)
    }

    @Test("Invariant 14: changed code, a tool that is not set up, or a cell with no statement runs nothing")
    func refusals() throws {
        let (message, cell) = cell()
        #expect(throws: VerificationError.changedSinceShown) {
            try compute.run(cell: message.stableID, shown: TextDigest(of: cell.code + " "))
        }
        let (gapMessage, gapCell) = self.cell(tool: .gap)
        #expect(throws: VerificationError.toolNotSetUp(.gap)) {
            try compute.run(cell: gapMessage.stableID, shown: TextDigest(of: gapCell.code))
        }
        cell.statementID = UUID()
        #expect(throws: VerificationError.noStatementAttached) {
            try compute.run(cell: message.stableID, shown: TextDigest(of: cell.code))
        }
        #expect(executor.jobs.isEmpty && (cell.runs ?? []).isEmpty)
    }

    @Test("Every run that started is recorded with how it ended; what the code reports is read from its last line")
    func outcomes() async throws {
        let cases: [(RunReport, RunOutcome, CellVerdict)] = [
            (.exited(0, stdout: "sangaku-result: counterexample (p, q) = (5, 3)\n"), .completed, .counterexample),
            (.exited(0, stdout: "done\n"), .completed, .inconclusive),
            (.exited(1, stdout: "sangaku-result: holds\n", stderr: "Traceback"), .exitedNonzero, .inconclusive),
            (RunReport(end: .timedOut, stdout: CappedText(text: "sangaku-result: holds"), stderr: CappedText(text: ""),
                       startedAt: .now, seconds: 120), .timedOut, .inconclusive),
            (RunReport(end: .memoryLimit, stdout: CappedText(text: ""), stderr: CappedText(text: ""), startedAt: .now,
                       seconds: 3), .memoryLimit, .inconclusive),
        ]
        let (message, cell) = cell()
        executor.script(.exited(0))
        for (index, (report, outcome, verdict)) in cases.enumerated() {
            executor.script(report)
            try compute.run(cell: message.stableID, shown: TextDigest(of: cell.code))
            try await waitUntil { (cell.runs ?? []).count == index + 1 }
            let latest = try #require(cell.runs?.max { $0.createdAt < $1.createdAt })
            #expect(latest.outcome == outcome && latest.verdict == verdict && !latest.passed, "\(outcome)")
        }
        executor.script(RunReport.couldNotStart("no sandbox", at: .now))
        try compute.run(cell: message.stableID, shown: TextDigest(of: cell.code))
        try await waitUntil { compute.lastFailure[cell.stableID] != nil }
        #expect((cell.runs ?? []).count == cases.count, "a run that never started is not evidence")
        #expect(CellOutputReader.read("x\nsangaku-result: holds  \n\n").verdict == .holds)
        #expect(CellOutputReader.read("sangaku-result: holds, mostly").verdict == .inconclusive)
    }

    @Test("Invariants 1 and 5: a counterexample refutes only when a person accepts it, in their own words")
    func refutation() async throws {
        let lemma3 = fixture.lemmas[2]
        let (message, cell) = cell()
        executor.script(.exited(0), .exited(0, stdout: "sangaku-result: counterexample (5, 3)\n"))
        try compute.run(cell: message.stableID, shown: TextDigest(of: cell.code))
        try await waitUntil { !(cell.runs ?? []).isEmpty }
        let evidence = try #require(cell.runs?.first)
        let graph = fixture.state.graph
        #expect(graph.state(for: fixture.problem)[lemma3.stableID]?.derived.own != .refuted, "a report changes nothing")
        #expect(throws: VerificationError.noteRequired) {
            try graph.acceptRefutation(lemma3.stableID, evidence: evidence.stableID, note: "  ", in: fixture.problem)
        }
        #expect(throws: VerificationError.noSuchEvidence) {
            try graph.acceptRefutation(fixture.lemmas[1].stableID, evidence: evidence.stableID, note: "x", in: fixture.problem)
        }
        let sweep = try #require(fixture.theorem.evidence?.first)
        #expect(throws: VerificationError.notACounterexample) {
            try graph.acceptRefutation(fixture.theorem.stableID, evidence: sweep.stableID, note: "x", in: fixture.problem)
        }
        try graph.acceptRefutation(lemma3.stableID, evidence: evidence.stableID,
                                   note: "Fails at $(p, q) = (5, 3)$.", in: fixture.problem)
        #expect(lemma3.refutationAcceptedByID == fixture.you.stableID && lemma3.refutationEvidenceID == evidence.stableID)
        #expect(graph.state(for: fixture.problem)[lemma3.stableID]?.derived.own == .refuted)
        let snapshot = ProblemSnapshot.make(problem: fixture.problem, branch: fixture.mainBranch,
                                            notation: fixture.state.problems.notation(for: fixture.problem),
                                            people: [fixture.you, fixture.mk], liveMessageIDs: [])
        #expect(PromptCarries(snapshot).refuted.contains { $0.line.contains("Fails at $(p, q) = (5, 3)$.") })
        try graph.withdrawRefutation(lemma3.stableID, in: fixture.problem)
        #expect(lemma3.refutationAcceptedByID == nil && (lemma3.evidence ?? []).contains { $0 === evidence })
    }

    @Test("A person's own cell is theirs, attached to a statement, and still waits for Run")
    func personCell() throws {
        let id = try compute.writeCell(on: fixture.mainBranch, statement: fixture.lemmas[2].stableID, tool: .python,
                                       code: "print(1)\n", scope: "one case", claim: "")
        let message = try #require(context.first(Message.self, stableID: id))
        #expect(message.author == .human(fixture.you.personID) && message.computeCell?.code == "print(1)\n")
        #expect(compute.state(of: try #require(message.computeCell)) == .waiting && executor.jobs.isEmpty)
        #expect(throws: VerificationError.self) {
            try compute.writeCell(on: fixture.mainBranch, statement: fixture.lemmas[2].stableID, tool: .python,
                                  code: "print(1)", scope: "  ", claim: "")
        }
    }
}

@Suite("Verification: citations")
struct CitationTests {
    private let fixture = PreviewFixtures.make()

    private static let atom = """
    <?xml version='1.0' encoding='UTF-8'?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <entry>
        <id>http://arxiv.org/abs/2301.00001v2</id>
        <published>2023-01-02T00:00:00Z</published>
        <title>Normal Sylow subgroups of groups of order p^2 q</title>
        <author><name>Ada Example</name></author>
        <author><name>Ben Sample</name></author>
      </entry>
    </feed>
    """
    private static let zbmath = """
    {"result":[{"title":{"title":"Abstract algebra"},"year":"1991","zbmath_url":"https://zbmath.org/53165",
    "contributors":{"authors":[{"name":"Dummit, David S."},{"name":"Foote, Richard M."}]}}],"status":{"internal_code":"ok"}}
    """
    private static let zbmathNone = """
    {"result":null,"status":{"internal_code":"successful access. No results found.","status_code":404}}
    """
    private static let emptyFeed = "<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>"

    private func service(_ transport: RoutedTransport) -> CitationService {
        CitationService(context: fixture.state.container.mainContext, saves: fixture.state.saves,
                        problems: fixture.state.problems, client: CitationLookupClient(transport: transport),
                        pause: .milliseconds(1), now: { Date(timeIntervalSinceReferenceDate: 800_500_000) })
    }

    @Test("Invariant 6: only the citation's query is sent; a match is found, silence everywhere is not found")
    func lookups() async throws {
        let transport = RoutedTransport(["export.arxiv.org": .body(200, Self.atom), "api.zbmath.org": .body(200, Self.zbmath)])
        let step = fixture.attemptA.sortedSteps[0]
        let found = try #require(step.citations?.first)
        found.status = .unverified
        let invented = try #require(fixture.attemptA.sortedSteps[5].citations?.first)
        let citations = service(RoutedTransport(["export.arxiv.org": .body(200, "<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>"),
                                                 "api.zbmath.org": .body(404, Self.zbmathNone)]))
        try citations.check([ShownCitation(id: invented.stableID, text: invented.rawText)])
        try await waitUntil { citations.checking.isEmpty }
        #expect(invented.status == .notFound && invented.resolvedURL == nil)

        let other = service(transport)
        try other.check([ShownCitation(id: found.stableID, text: found.rawText)])
        try await waitUntil { other.checking.isEmpty }
        #expect(found.status == .found && found.matchedTitle == "Abstract algebra")
        #expect(found.resolvedURL == "https://zbmath.org/53165" && found.checkedByID == fixture.you.stableID)
        let sent = transport.urls.map { $0.absoluteString }.joined(separator: " ")
        #expect(!sent.contains("Sylow") && !sent.contains(fixture.problem.title.split(separator: " ").first.map(String.init) ?? "§"),
                "nothing of the problem is sent")
        #expect(transport.urls.allSatisfy { $0.scheme == "https" })
    }

    @Test("Invariant 6: a lookup that cannot decide leaves the citation unverified, never not found")
    func failures() async throws {
        let citation = try #require(fixture.attemptA.sortedSteps[5].citations?.first)
        citation.status = .unverified
        for transport in [RoutedTransport(["export.arxiv.org": .error(.timedOut), "api.zbmath.org": .body(404, Self.zbmathNone)]),
                          RoutedTransport(["export.arxiv.org": .body(429, ""), "api.zbmath.org": .body(200, "{}")]),
                          RoutedTransport(["export.arxiv.org": .body(200, Self.emptyFeed), "api.zbmath.org": .body(200, "{}")]),
                          RoutedTransport(["export.arxiv.org": .body(503, ""), "api.zbmath.org": .error(.notConnectedToInternet)]),
                          RoutedTransport(["export.arxiv.org": .body(200, "not xml"), "api.zbmath.org": .body(404, "missing")])] {
            let citations = service(transport)
            try citations.check([ShownCitation(id: citation.stableID, text: citation.rawText)])
            try await waitUntil { citations.checking.isEmpty }
            #expect(citation.status == .unverified && citation.lookupDetail?.isEmpty == false, "\(citation.lookupDetail ?? "")")
        }
    }

    @Test("Invariant 6: exactly the query shown is sent; after an empty arXiv answer, a narrower one of its words")
    func sent() async throws {
        let transport = RoutedTransport(["export.arxiv.org": .body(200, Self.emptyFeed), "api.zbmath.org": .body(404, Self.zbmathNone)])
        let citations = service(transport)
        let raw = "Kessler & Varga (2019), On normal Sylow subgroups of solvable groups, J. Algebra"
        let id = try citations.add(raw, to: fixture.attemptA.sortedSteps[1].stableID)
        try citations.check([ShownCitation(id: id, text: raw)])
        try await waitUntil { citations.checking.isEmpty }
        func query(_ url: URL, _ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
        let shown = Set(CitationRules.query(raw).split(separator: " ").map(String.init))
        let zbmath = transport.urls.filter { $0.host() == "api.zbmath.org" }.compactMap { query($0, "search_string") }
        #expect(zbmath == [CitationRules.query(raw)], "zbMATH Open gets the query shown")
        let arxiv = transport.urls.filter { $0.host() == "export.arxiv.org" }.compactMap { query($0, "search_query") }
        #expect(arxiv.count == 2, "every word, then the first few")
        for sent in arxiv {
            let words = sent.components(separatedBy: " AND ").map { $0.replacingOccurrences(of: "all:", with: "") }
            #expect(Set(words).isSubset(of: shown), "\(sent)")
        }
        #expect(arxiv.last?.components(separatedBy: " AND ").count == 3)
    }

    @Test("Stop: the lookup under way records nothing, and the stopped check ending late does not clear a new one")
    func stop() async throws {
        let citation = try #require(fixture.attemptA.sortedSteps[5].citations?.first)
        citation.status = .unverified
        let before = (citation.checkedAt, citation.lookupDetail)
        let transport = RoutedTransport(["export.arxiv.org": .slow(.seconds(5), 200, Self.emptyFeed),
                                         "api.zbmath.org": .body(404, Self.zbmathNone)])
        let citations = service(transport)
        let shown = [ShownCitation(id: citation.stableID, text: citation.rawText)]
        try citations.check(shown)
        try await waitUntil { transport.urls.count == 1 }
        citations.stop()
        #expect(citations.checking.isEmpty)
        try citations.check(shown)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!citations.checking.isEmpty, "the new check is still under way")
        citations.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(citation.checkedAt == before.0 && citation.lookupDetail == before.1 && citation.status == .unverified)
        #expect(!transport.urls.contains { $0.host() == "api.zbmath.org" }, "nothing more is sent once stopped")
    }

    @Test("A lookup that cannot decide leaves a citation an earlier lookup found as it was")
    func undecidedKeepsDecided() async throws {
        let step = fixture.attemptA.sortedSteps[0]
        let found = try #require(step.citations?.first)
        found.status = .unverified
        let first = service(RoutedTransport(["export.arxiv.org": .body(200, Self.atom), "api.zbmath.org": .body(200, Self.zbmath)]))
        try first.check([ShownCitation(id: found.stableID, text: found.rawText)])
        try await waitUntil { first.checking.isEmpty }
        #expect(found.status == .found)
        let offline = service(RoutedTransport(["export.arxiv.org": .error(.notConnectedToInternet),
                                               "api.zbmath.org": .error(.notConnectedToInternet)]))
        try offline.check([ShownCitation(id: found.stableID, text: found.rawText)])
        try await waitUntil { offline.checking.isEmpty }
        #expect(found.status == .found && found.matchedTitle == "Abstract algebra" && found.resolvedURL != nil)
    }

    @Test("Matching: an author named, half the title, the year within one; links only over https to an index")
    func rules() {
        let book = CitationCandidate(index: "zbMATH Open", title: "Abstract algebra", surnames: ["Dummit", "Foote"],
                                     year: 1991, url: "https://zbmath.org/53165")
        #expect(CitationRules.matches("Dummit & Foote, Abstract Algebra, 3rd ed., §4.5", book))
        #expect(CitationRules.matches("Dummit and Foote (1991), Abstract Algebra", book))
        #expect(!CitationRules.matches("Dummit and Foote (2004), Abstract Algebra", book), "years apart")
        #expect(!CitationRules.matches("Lang, Algebra", book), "no author named")
        #expect(CitationRules.terms("Kessler & Varga (2019), \\emph{J. Algebra}, Lemma 2.4") == ["kessler", "varga", "algebra"])
        #expect(CitationRules.query("Kessler & Varga (2019), J. Algebra, Lemma 2.4") == "kessler varga algebra 2019")
        #expect(!CitationRules.canLookUp("Lemma 2.4"))
        #expect(CitationRules.verdict("x", answers: []) == .unverified(""))
        #expect(CitationRules.link(status: .found, url: "https://zbmath.org/53165") != nil)
        for (status, url) in [(CitationStatus.unverified, "https://zbmath.org/1"), (.notFound, "https://zbmath.org/1"),
                              (.found, "http://zbmath.org/1"), (.found, "https://example.com/1"),
                              (.found, "javascript:alert(1)"), (.found, "https://zbmath.org.example.com/1")] {
            #expect(CitationRules.link(status: status, url: url) == nil, "\(status) \(url)")
        }
        let feed = CitationLookupClient.parseArxiv(200, Data(Self.atom.utf8))
        #expect(feed?.first?.surnames == ["Example", "Sample"] && feed?.first?.year == 2023)
        #expect(feed?.first?.url == "https://arxiv.org/abs/2301.00001v2")
        #expect(CitationLookupClient.parseZbmath(404, Data(Self.zbmathNone.utf8)) == [])
        #expect(CitationLookupClient.parseZbmath(404, Data("{}".utf8)) == nil)
        #expect(CitationLookupClient.parseZbmath(200, Data("{}".utf8)) == nil, "an answer without documents is no answer")
        #expect(CitationLookupClient.parseZbmath(200, Data(#"{"result":[]}"#.utf8)) == [])
    }

    @Test("People add and remove citations; a removed one is kept for provenance, and a changed one is not checked")
    func editing() throws {
        let citations = service(RoutedTransport([:]))
        let step = fixture.attemptA.sortedSteps[2]
        let id = try citations.add("  Isaacs, Finite Group Theory, Theorem 1.16  ", to: step.stableID)
        let citation = try #require(fixture.state.container.mainContext.first(Citation.self, stableID: id))
        #expect(citation.rawText == "Isaacs, Finite Group Theory, Theorem 1.16" && citation.status == .unverified)
        #expect(citation.author == .human(fixture.you.personID))
        #expect(throws: VerificationError.self) { try citations.add("Isaacs, Finite Group Theory, Theorem 1.16", to: step.stableID) }
        #expect(throws: VerificationError.changedSinceShown) {
            try citations.check([ShownCitation(id: id, text: "something else")])
        }
        try citations.remove(id)
        #expect(citation.removedAt != nil && (step.citations ?? []).contains { $0 === citation })
        #expect(throws: VerificationError.noSuchCitation) { try citations.remove(id) }
    }

    @Test("A model's citations arrive unverified with the attempt, credited to the model")
    func fromAttempts() {
        let parsed = AttemptParser.parse(#"{"overview":"","steps":[{"text":"By Sylow.","establishes":"counts","confidence":"standard","citations":["Isaacs, Finite Group Theory, Theorem 1.16","Isaacs, Finite Group Theory, Theorem 1.16","bad\u0007"]}]}"#, lenient: false)
        guard case .clean(let attempt) = parsed else {
            Issue.record("expected a clean parse")
            return
        }
        #expect(attempt.steps.first?.citations == ["Isaacs, Finite Group Theory, Theorem 1.16"])
        let older = AttemptParser.parse(#"{"overview":"","steps":[{"text":"t","establishes":"e","confidence":"routine"}]}"#, lenient: false)
        if case .clean(let attempt) = older { #expect(attempt.steps.first?.citations == []) } else { Issue.record("older output still reads") }
    }
}
