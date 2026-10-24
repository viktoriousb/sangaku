import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import sangaku

@Suite("Verification: styles and words")
struct VerificationStyleTests {
    private let lean: [LeanStanding] = [.notChecked, .didNotCompile, .namesUnusedStatement, .axiomCheckMissing, .incomplete,
                                        .awaitingFidelity, .statementDiffers, .verified]
    private let fidelity: [FidelityStanding] = [.pending, .confirmed(by: nil), .differs(by: nil), .outdated]
    private var runs: [StatusStyle] {
        [StatusStyle.style(for: CellState.waiting), StatusStyle.style(for: CellState.running)]
            + RunOutcome.allCases.flatMap { outcome in CellVerdict.allCases.map { StatusStyle.style(outcome: outcome, verdict: $0) } }
    }

    @Test("Invariant 3: every new state has its own glyph and words, and only the derived status uses ⊢")
    func styles() {
        let leanStyles = lean.map(StatusStyle.style(for:))
        let families = [leanStyles, fidelity.map(StatusStyle.style(for:)), CitationStatus.allCases.map(StatusStyle.style(for:))]
        for family in families {
            #expect(family.allSatisfy { !$0.glyph.isEmpty && !$0.label.isEmpty })
            #expect(Set(family.map(\.glyph)).count == family.count && Set(family.map(\.label)).count == family.count)
        }
        let all = families.joined() + runs
        #expect(all.filter { $0.glyph == "⊢" } == [StatusStyle.style(for: .formallyVerified)])
        #expect(all.filter { $0.borderToken == .verified || $0.fill == .verifiedFill }.count == 1)
        #expect(!all.contains { $0.borderToken == .modelChecked }, "blue means checked by a model, and none of these is")
        let compiles = StatusStyle.style(for: LeanStanding.awaitingFidelity)
        #expect(compiles.isProvisional && compiles.border == .dashed && compiles.ink == .secondaryInk)
        let counterexample = StatusStyle.style(outcome: .completed, verdict: .counterexample)
        #expect(counterexample.glyph != "✗" && counterexample.borderToken != .refuted && counterexample.fill != .refutedFill,
                "only a person refutes (invariant 1)")
        #expect(!all.contains { $0.borderToken == .refuted }, "a failed check or a citation not found is not a refutation")
        #expect(StatusStyle.style(for: CitationStatus.notFound).strikesText)
        #expect(StatusStyle.style(for: CitationStatus.found).glyph != "✓", "a found citation is not a checked one")
    }

    @Test("Invariant 3: a Lean card says verified exactly when rule 2 holds")
    func standingAgreesWithRule2() {
        var generator = SeededGenerator(state: 8)
        for _ in 0..<500 {
            let axioms: AxiomCheck = switch Int.random(in: 0..<4, using: &generator) {
            case 0: .notRun
            case 1: .ran(declaration: "d", axioms: [])
            case 2: .ran(declaration: "d", axioms: ["propext", "Quot.sound"])
            default: .ran(declaration: "d", axioms: ["propext", "sorryAx"])
            }
            let inputs = StatusInputs.Lean(ran: Bool.random(using: &generator), errorCount: Int.random(in: 0...1, using: &generator),
                                           sorryCount: Int.random(in: 0...1, using: &generator), axiomCheck: axioms,
                                           namesOnlyUsed: Bool.random(using: &generator),
                                           fidelityConfirmed: Bool.random(using: &generator))
            let verdict: FidelityVerdict? = [nil, .matches, .differs].randomElement(using: &generator)!
            #expect((LeanStanding.of(inputs, latestVerdict: verdict) == .verified) == StatusRules.leanVerifies(inputs))
        }
        #expect(LeanStanding.of(nil, latestVerdict: nil) == .notChecked)
    }

    private static let fixture = PreviewFixtures.makeVerified()
    private var authors: AuthorDirectory {
        AuthorDirectory(problem: Self.fixture.problem, people: [Self.fixture.you, Self.fixture.mk], catalog: .standard)
    }

    @Test("Invariant 8: run words say what was reported over what scope, never passed, proved or verified")
    func words() {
        let base = EvidenceFact(id: UUID(), statementID: UUID(), tool: .gap, scope: "orders p²q ≤ 100", outcome: .completed,
                                verdict: .holds, detail: "", runByID: nil, createdAt: .now, seconds: 1, truncated: false,
                                code: "", output: "", errorText: "", canRefute: false)
        for outcome in RunOutcome.allCases {
            for verdict in CellVerdict.allCases {
                var fact = base
                fact.outcome = outcome
                fact.verdict = verdict
                fact.detail = "$\\frac{a$ printed by the program"
                let words = (VerificationWording.run(fact) + " " + VerificationWording.runLine(fact, authors: authors)).lowercased()
                for claim in ["passed", "proves", "proved", "verified", "true"] { #expect(!words.contains(claim), "\(words)") }
                #expect(!VerificationWording.run(fact).contains("printed by the program"),
                        "what a program printed is never typeset with the app's words (invariant 16)")
            }
        }
        #expect(VerificationWording.run(base) == "No counterexample found (scope: orders p²q ≤ 100).")
        var counterexample = base
        counterexample.verdict = .counterexample
        counterexample.detail = "A4 has 4 Sylow 3-subgroups"
        #expect(VerificationWording.run(counterexample) == "Its code reported a counterexample (scope: orders p²q ≤ 100).")
        #expect(VerificationWording.reported(counterexample) == "Reported: A4 has 4 Sylow 3-subgroups")
        #expect(VerificationWording.reported(base) == nil)
        #expect(VerificationWording.runLine(base, authors: authors).hasPrefix("Run by \(AuthorDirectory.missingPerson) · "),
                "one wording for a person no longer listed")
        #expect(VerificationWording.runCount(1).isEmpty && VerificationWording.runCount(3) == "3 runs; latest: ")
        #expect(VerificationWording.sorries([LeanLocation(line: 4, column: 2), LeanLocation(line: 9, column: 2)])
                == "2 sorries at lines 4 and 9")
        #expect(VerificationWording.moduleLine(others: ["Lem 1", "Lem 2"]).contains("Lem 1 and Lem 2"))
        #expect(VerificationWording.lineCount(400) == "400 lines; scroll to read them all.")
        for text in [VerificationWording.waitsWhileBlind, CompareWording.askWhileBlind, VerificationWording.scoutExplanation] {
            for name in ["Model ", "Claude", "Anthropic"] { #expect(!text.contains(name)) }
        }
        #expect(VerificationWording.waitsWhileBlind.contains("Turn blind mode off") && !VerificationWording.waitsWhileBlind.contains("Record"),
                "recording a verdict does not let a formalizer or a scout be asked")
        #expect(ReviewLayoutMode.resolve(width: 876) == .sideBySide && ReviewLayoutMode.resolve(width: 875) == .stacked)
    }

    @Test("Invariants 6 and 12: the words of a Lean card and a citation say no more than their standing")
    func cardWords() throws {
        let you = Self.fixture.you.stableID
        #expect(VerificationWording.fidelity(.confirmed(by: you), label: "Lem 1", authors: authors) == "Confirmed by You.")
        #expect(VerificationWording.fidelity(.differs(by: nil), label: "Lem 1", authors: authors)
                == "\(AuthorDirectory.missingPerson) found that it says something else.")
        #expect(VerificationWording.fidelity(.pending, label: "Lem 1", authors: authors).hasPrefix("No person has confirmed"))
        let lemma = try #require((Self.fixture.problem.statements ?? []).first { $0.label == "Lem 2" })
        let facts = LeanFacts.read(lemma, people: Self.fixture.state.problems.personIDs())
        let checked = try #require(VerificationWording.checked(facts, authors: authors))
        #expect(checked.contains("with Lean 4.35.0, Mathlib v4.35.0; code by Model A."), "\(checked)")
        for line in [checked, VerificationWording.axioms(facts)] {
            for claim in ["verified", "proved", "passed"] { #expect(!line.lowercased().contains(claim), "\(line)") }
        }
        let citations = CitationFact.read(Self.fixture.attemptA)
        var found = try #require(citations.first { $0.status == .found })
        found.matchedTitle = "Abstract algebra"
        found.indexName = "zbMATH Open"
        #expect(VerificationWording.lookup(found) == "Matches \u{201C}Abstract algebra\u{201D} in zbMATH Open.")
        let undecided = try #require(citations.first { $0.detail != nil })
        #expect(VerificationWording.lookup(undecided) == "Last lookup could not decide: arXiv: timed out; zbMATH Open: offline.")
        #expect(VerificationWording.lookup(try #require(citations.first { $0.status == .notFound })) == nil)
        #expect(VerificationWording.sends("Kessler & Varga (2019), J. Algebra") == "Sends: " + CitationRules.query("Kessler & Varga (2019), J. Algebra"))
        #expect(VerificationWording.sends("Lemma 2.4") == "Too little to look up; nothing is sent.")
    }

    @Test("Invariant 14: code of any length is shown whole, line by line; hidden characters are refused")
    func codeShown() {
        let text = (1...20_000).map { "x_\($0) = \($0) # a line of code" }.joined(separator: "\n") + "\n\nend"
        #expect(text.count > 300_000)
        #expect(ToolTextBox.lines(of: text).joined(separator: "\n") == text, "nothing is cut")
        #expect(CodeText.refusal("print(1)\n\tpass") == nil)
        for hidden in ["\u{202E}", "\u{2066}", "\u{200B}", "\u{FEFF}", "\u{00AD}", "\u{2028}", "\u{2029}", "\u{85}", "\u{7}", "\r",
                       "\u{E000}"] {
            #expect(CodeText.refusal("a = 1" + hidden + "\nb = 2") != nil, "\(hidden.unicodeScalars.map(\.value))")
            #expect(TaskOutputParser.code("a = 1" + hidden) == nil)
        }
        #expect(CodeText.name("\u{202E}".unicodeScalars.first!) == "U+202E")
        #expect(CodeText.refusal(String(repeating: "x", count: CodeText.maximumLength + 1)) == "The code is longer than 200 KB.")
        #expect(FidelitySheet.confirmShortcut == nil, "Return never records that a Lean statement matches (invariant 12)")
    }
}

@Suite("Verification: what the screens read")
struct VerificationStateTests {
    private let fixture = PreviewFixtures.makeVerified()

    private func statement(_ label: String) -> Statement? {
        (fixture.problem.statements ?? []).first { $0.label == label }
    }

    @Test("The verified example reads as each state the cards draw")
    func states() throws {
        let state = VerificationState.read(problem: fixture.problem, people: fixture.state.problems.personIDs())
        func standing(_ label: String) -> LeanStanding? { statement(label).flatMap { state.lean[$0.stableID]?.standing } }
        #expect(standing("Lem 1") == .verified && standing("Lem 2") == .awaitingFidelity)
        #expect(standing("Lem 4") == .incomplete && standing("Lem 7") == .didNotCompile && standing("Lem 6") == .notChecked)
        #expect(state.lean[try #require(statement("Lem 1")).stableID]?.fidelity == .confirmed(by: fixture.you.stableID))
        let claim = try #require(statement("Claim 2"))
        let run = try #require(state.evidence[claim.stableID]?.first)
        #expect(run.canRefute && run.detail == "A4 has 4 Sylow 3-subgroups")
        #expect(claim.evidence?.first?.cell?.message?.kind == .compute)
        let sweep = try #require(state.evidence[fixture.theorem.stableID])
        #expect(sweep.map(\.outcome) == [.timedOut, .completed], "newest first")
        #expect(fixture.theorem.evidence?.first { $0.outcome == .completed }?.cell?.message?.author == .human(fixture.you.personID))
        let citations = CitationFact.read(fixture.attemptA)
        #expect(citations.map(\.status) == [.found, .unverified, .unverified, .notFound])
        #expect(citations.allSatisfy { $0.link == nil }, "no citation of the example has a link to show")
        #expect(citations.first { $0.detail != nil }?.detail == "arXiv: timed out; zbMATH Open: offline")
    }

    @Test("Invariant 9: sheets that name models wait while blind mode hides them, whoever asked")
    func blind() throws {
        let window = WindowState()
        window.select(problem: fixture.problem)
        let services = VerificationServices(lean: fixture.state.lean, compute: fixture.state.compute,
                                            citations: fixture.state.citations, graph: fixture.state.graph,
                                            problems: fixture.state.problems)
        let lemma = try #require(statement("Lem 3"))
        window.activeView = .compare
        window.blindMode = true
        for intent in [VerificationIntent.formalize(statement: lemma.stableID),
                       .askForCheck(ScoutSeed(claim: "x", statements: [lemma.stableID], fromCompare: true))] {
            VerificationIntentHandler.perform(intent, window: window, services: services)
            #expect(window.verificationSheet == nil && window.verificationNotice != nil, "\(intent)")
        }
        window.verificationSheet = .scout(ScoutSeed(claim: "x", statements: [lemma.stableID]))
        #expect(VerificationSheetHost.presented(in: window) == nil, "asked for before blind mode came on")
        window.activeView = .review
        #expect(VerificationSheetHost.presented(in: window) == window.verificationSheet)
        window.activeView = .compare
        VerificationIntentHandler.perform(.confirmStatement(lemma.stableID), window: window, services: services)
        #expect(VerificationSheetHost.presented(in: window) == .fidelity(statement: lemma.stableID),
                "confirming a statement names no model")
        // A verdict recorded in Compare reveals the pair, not the slots a sheet would list: asking still waits.
        window.verificationSheet = nil
        VerificationIntentHandler.perform(.askForCheck(ScoutSeed(claim: "x", statements: [lemma.stableID], fromCompare: true)),
                                          window: window, services: services)
        #expect(window.verificationSheet == nil && window.verificationNotice == VerificationWording.waitsWhileBlind)
    }

    @Test("Invariant 9: an intent waits while blind exactly when the sheet it opens does")
    func blindListsAgree() throws {
        let id = UUID()
        let window = WindowState()
        let pairs: [(VerificationIntent, VerificationSheet)] = [
            (.formalize(statement: id), .formalize(statement: id)),
            (.checkLean(statement: id, candidate: .current, editing: false), .leanCheck(statement: id, candidate: .current, editing: false)),
            (.confirmStatement(id), .fidelity(statement: id)),
            (.askForCheck(ScoutSeed(claim: "x", statements: [id])), .scout(ScoutSeed(claim: "x", statements: [id]))),
            (.writeCell(statement: id, basedOn: nil), .cellEditor(statement: id, basedOn: nil)),
            (.acceptRefutation(statement: id, evidence: id), .refutation(statement: id, evidence: id)),
            (.checkCitations(attempt: id), .citationCheck(attempt: id)),
            (.addCitation(step: id), .citationAdd(step: id)),
        ]
        for (intent, sheet) in pairs {
            #expect(intent.waitsWhileBlind == sheet.waitsWhileBlind, "\(intent)")
            window.verificationSheet = nil
            VerificationIntentHandler.perform(intent, window: window, services: VerificationServices())
            #expect(window.verificationSheet == sheet, "\(intent) opens \(sheet)")
        }
    }

    @Test("The handler acts at once on what needs no sheet, and says why when it cannot")
    func handlerActions() async throws {
        let window = WindowState()
        window.select(problem: fixture.problem)
        let services = VerificationServices(lean: fixture.state.lean, compute: fixture.state.compute,
                                            citations: fixture.state.citations, graph: fixture.state.graph,
                                            problems: fixture.state.problems)
        // Remove a citation; removing it again is refused in words.
        let citation = try #require(fixture.attemptA.sortedSteps[2].citations?.first { $0.removedAt == nil })
        VerificationIntentHandler.perform(.removeCitation(citation.stableID), window: window, services: services)
        #expect(citation.removedAt != nil && window.verificationNotice == nil)
        VerificationIntentHandler.perform(.removeCitation(citation.stableID), window: window, services: services)
        #expect(window.verificationNotice == VerificationError.noSuchCitation.message)
        // Withdrawing a refutation nobody accepted is refused; one accepted is withdrawn.
        let claim = try #require(statement("Claim 2"))
        VerificationIntentHandler.perform(.withdrawRefutation(statement: claim.stableID), window: window, services: services)
        #expect(window.verificationNotice == VerificationError.notRefuted.message)
        let run = try #require(claim.evidence?.first)
        try fixture.state.graph.acceptRefutation(claim.stableID, evidence: run.stableID, note: "A4 is a counterexample.",
                                                 in: fixture.problem)
        VerificationIntentHandler.perform(.withdrawRefutation(statement: claim.stableID), window: window, services: services)
        #expect(claim.refutationAcceptedByID == nil && window.verificationNotice == nil)
        // A person's review of a Lean statement is withdrawn through the window too.
        let lemma1 = try #require(statement("Lem 1"))
        VerificationIntentHandler.perform(.withdrawFidelity(statement: lemma1.stableID), window: window, services: services)
        #expect(lemma1.fidelityReviews?.allSatisfy { $0.withdrawnAt != nil } == true)
        VerificationIntentHandler.perform(.withdrawFidelity(statement: lemma1.stableID), window: window, services: services)
        #expect(window.verificationNotice == VerificationError.noFidelityToWithdraw.message)
        // Stops with nothing running change nothing.
        for intent in [VerificationIntent.stopLean(problem: fixture.problem.stableID), .stopCell(UUID()), .stopCitations] {
            window.verificationNotice = nil
            VerificationIntentHandler.perform(intent, window: window, services: services)
            #expect(window.verificationNotice == nil && window.verificationSheet == nil, "\(intent)")
        }
    }

    @Test("A refused action says why in the window; Run never runs code that changed")
    func refusals() throws {
        let window = WindowState()
        window.select(problem: fixture.problem)
        let services = VerificationServices(lean: fixture.state.lean, compute: fixture.state.compute,
                                            citations: fixture.state.citations, graph: fixture.state.graph,
                                            problems: fixture.state.problems)
        let message = try #require(fixture.mainBranch.sortedMessages.first { $0.computeCell?.tool == .python })
        VerificationIntentHandler.perform(.runCell(messageID: message.stableID, shown: TextDigest(of: "other code")),
                                          window: window, services: services)
        #expect(window.verificationNotice == VerificationError.changedSinceShown.message)
    }

    @Test("Invariant 9: a Compare search names the attempts only as Attempt 1 and Attempt 2")
    func compareSeed() throws {
        let state = ComparisonState.read(fixture.attemptA, fixture.attemptB, in: fixture.problem,
                                         people: fixture.state.problems.personIDs())
        let row = try #require(state.rows.first { $0.a?.index == 5 })
        let seed = CompareSearch.seed(row, problem: fixture.problem)
        #expect(seed.claim.contains("Attempt 1, step 5") && !seed.claim.contains("Model"))
        #expect(seed.statements.first == fixture.lemmas[2].stableID, "Lem 3 rests on step 5 of A")
        #expect(seed.fromCompare && Set(seed.statements).count == seed.statements.count)
    }
}

@Suite("Verification: layout and renders", .serialized)
struct VerificationLayoutTests {
    /// Kept for the whole run: the sheets build what they show in tasks, which may run after a test has returned.
    private static let fixture = PreviewFixtures.makeVerified()
    private var fixture: PreviewFixtures.Handles { Self.fixture }

    private func environment<V: View>(_ view: V) -> some View {
        view.appEnvironment(fixture.state)
            .environment(\.mathContext, fixture.mathContext)
            .modelContainer(fixture.state.container)
    }

    private var authors: AuthorDirectory {
        AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
    }

    private var panel: VerificationPanel {
        let people = fixture.state.problems.personIDs()
        return VerificationPanel(problem: fixture.problem, attempt: fixture.attemptA,
                                 graph: fixture.state.graph.state(for: fixture.problem, people: people),
                                 verification: VerificationState.read(problem: fixture.problem, people: people),
                                 citations: CitationFact.read(fixture.attemptA), currentStepID: nil, authors: authors)
    }

    @Test("The panel fits the narrowest workspace and asks for no width of its own; Review fits a window of the minimum size")
    func fits() {
        let narrow = WindowRoot.contentMinWidth - 40
        #expect(NSHostingController(rootView: environment(panel)).sizeThatFits(in: CGSize(width: narrow, height: .greatestFiniteMagnitude)).width <= narrow)
        #expect(NSHostingController(rootView: environment(panel)).sizeThatFits(in: .zero).width <= WindowRoot.contentMinWidth)
        let window = WindowState()
        window.select(problem: fixture.problem)
        let size = NSHostingController(rootView: environment(ReviewView(problem: fixture.problem, window: window)))
            .sizeThatFits(in: .zero)
        #expect(size.width <= WindowRoot.contentMinWidth && size.height <= WindowRoot.minimumHeight - 52)
    }

    @Test("Side by side, the steps and the panel fit the width that chose that layout, the panel at its own width")
    func sideBySide() {
        let width = CGFloat(876)
        let columns = environment(ReviewColumns(mode: ReviewLayoutMode.resolve(width: width)) {
            Color.clear.frame(height: 400)
        } panel: {
            panel
        })
        let size = NSHostingController(rootView: columns).sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        #expect(ReviewLayoutMode.resolve(width: width) == .sideBySide && size.width <= width, "\(size)")
        let stacked = environment(ReviewColumns(mode: .stacked) { Color.clear.frame(height: 400) } panel: { panel })
        let stackedSize = NSHostingController(rootView: stacked).sizeThatFits(in: CGSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        #expect(stackedSize.width <= 500)
    }

    /// With `SANGAKU_PREVIEW_DIR` set, writes PNGs for a visual check (pass `TEST_RUNNER_SANGAKU_PREVIEW_DIR`).
    private func render(_ name: String, width: CGFloat, dark: Bool = false, @ViewBuilder _ view: () -> some View) throws {
        let content = environment(view())
            .frame(width: width)
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "\(name) did not render")
        if let folder = ProcessInfo.processInfo.environment["SANGAKU_PREVIEW_DIR"] {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
        }
    }

    private func statement(_ label: String) -> Statement {
        (fixture.problem.statements ?? []).first { $0.label == label }!
    }

    @Test("Smoke renders: the panel, the thread's cells and draft, and the sheets")
    func renders() throws {
        try render("verification-panel", width: 340) { panel }
        try render("verification-panel-dark", width: 340, dark: true) { panel }
        let messages = fixture.mainBranch.sortedMessages.filter { $0.kind == .compute || $0.kind == .leanDraft }
        for (index, message) in messages.enumerated() {
            try render("verification-thread-\(index)", width: 700) {
                MessageRow(message: message, stream: nil, authors: authors, onViewContext: { _ in }, onStop: {})
            }
        }
        try render("verification-check-sheet", width: 640) {
            LeanCheckSheet(problem: fixture.problem, statement: statement("Lem 3"), candidate: .current, startsEditing: false)
        }
        try render("verification-fidelity-sheet", width: 640) {
            FidelitySheet(problem: fixture.problem, statement: statement("Lem 2"))
        }
        try render("verification-refutation-sheet", width: 600) {
            RefutationSheet(problem: fixture.problem, statement: statement("Claim 2"),
                            evidence: statement("Claim 2").evidence!.first!)
        }
        try render("verification-citation-sheet", width: 560) { CitationCheckSheet(attempt: fixture.attemptA) }
        try render("verification-scout-sheet", width: 560) {
            ScoutSheet(problem: fixture.problem, seed: ScoutSeed(claim: statement("Lem 3").statementLaTeX,
                                                                 statements: [statement("Lem 3").stableID]),
                       branch: fixture.mainBranch)
        }
        try render("verification-formalize-sheet", width: 560) {
            FormalizeSheet(problem: fixture.problem, statement: statement("Lem 6"), branch: fixture.mainBranch)
        }
        try render("verification-check-sheet-editing-dark", width: 640, dark: true) {
            LeanCheckSheet(problem: fixture.problem, statement: statement("Lem 3"), candidate: .current, startsEditing: true)
        }
        try render("verification-cell-editor", width: 600) {
            CellEditorSheet(problem: fixture.problem, statement: statement("Lem 3"), basedOn: nil, branch: fixture.mainBranch)
        }
        try render("verification-citation-add", width: 480) { CitationAddSheet(step: fixture.attemptA.sortedSteps[0]) }
        let window = WindowState()
        window.verificationNotice = VerificationWording.waitsWhileBlind
        try render("verification-notice", width: 640) { VerificationNoticeBanner(window: window) }
        try render("verification-settings", width: 560) {
            Form {
                ToolSettingsSection(settings: fixture.state.toolSettings)
                LimitsSettingsSection(settings: fixture.state.toolSettings)
                LeanSettingsSection(lean: fixture.state.lean, settings: fixture.state.toolSettings)
            }
        }
    }
}

/// Source scans: who may write what, pinned the way the no-deletion scan pins deletions. A scan that reads nothing fails.
@Suite("Verification: who writes what")
struct TrustScanTests {
    private func lines(matching needle: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "sangaku")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            where line.contains(needle) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("///")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                found.append(url.lastPathComponent)
            }
        }
        #expect(scanned > 100, "the scan read the app's sources")
        return found
    }

    @Test("Invariants 1, 12 and 14: one writer each for processes, axiom results, fidelity, refutations and settings")
    func writers() throws {
        let rules: [(String, Set<String>)] = [
            ("posix_spawn(", ["ProcessExecutor.swift"]),
            ("Process()", []),
            ("sandbox-exec", ["ProcessExecutor.swift"]),
            ("axiomCheckedDeclaration = ", ["LeanResult+Outcome.swift"]),
            ("checkedDigest = ", ["LeanResult+Outcome.swift"]),
            ("FidelityReview(", ["LeanService.swift", "PreviewFixtures.swift"]),
            ("refutationAcceptedByID = ", ["StatementGraph.swift", "PreviewFixtures.swift"]),
            ("UserDefaults", ["ToolSettings.swift"]),
            // A job for written code is made only from a click on what is stored or planned; `typed` is for tests.
            ("typed(by", ["Approval.swift"]),
            ("try Approval.given(", ["LeanService.swift", "ComputeService.swift"]),
            ("Evidence(", ["ComputeService.swift", "PreviewFixtures.swift"]),
            ("withdrawnAt = ", ["ReviewManager.swift", "LeanService.swift"]),
            // 8b: an export runs only from a click on the plan shown; a person marks a result imported.
            ("ExportApproval.given(", ["ExportService.swift"]),
            (".exportKit(", ["ExportService.swift"]),
            (".exportBuild(", ["ExportService.swift"]),
            (".exportLatex(", ["ExportService.swift"]),
            (".exportGitStatus(", ["ExportService.swift"]),
            (".exportGitInit(", ["ExportService.swift"]),
            (".exportGitAdd(", ["ExportService.swift"]),
            (".exportGitCommit(", ["ExportService.swift"]),
            ("importedSource = ", ["StatementGraph.swift"]),
            ("importedByID = ", ["StatementGraph.swift"]),
            ("matchedAuthors = ", ["CitationService.swift"]),
            ("TeXFragment(gated:", ["TeXGate.swift"]),
            // What an export writes is made by its writers, and the manifest and the LaTeX file by the service.
            ("ExportFile(", ["HashtagWriter.swift", "LeanProjectWriter.swift", "ExportService.swift"]),
        ]
        for (needle, allowed) in rules {
            let files = Set(try lines(matching: needle))
            #expect(files.isSubset(of: allowed), "\(needle): \(files.subtracting(allowed).sorted())")
        }
        #expect(try lines(matching: "posix_spawn(").contains("ProcessExecutor.swift"), "the scan finds the one spawn")
        #expect(try lines(matching: "typed(by").contains("Approval.swift"), "the scan finds the definition")
    }

    @Test("What a step establishes is typeset wherever a row shows it, never printed with its dollars")
    func labelsTypeset() throws {
        #expect(try lines(matching: #" Text("Establishes: "#).isEmpty, "a plain Text, not MathText")
        #expect(try lines(matching: #"MathText("Establishes: ""#).sorted() == ["ReviewStepRow.swift", "StepRow.swift"])
    }

    @Test("Invariant 16: what a program printed, and code, are never typeset")
    func neverTypeset() throws {
        for needle in ["MathText(fact.detail", "MathText(fact.output", "MathText(evidence.output", "MathText(cell.code",
                       "MathText(reading.detail", "MathText(VerificationWording.reported"] {
            #expect(try lines(matching: needle).isEmpty, "\(needle)")
        }
    }
}
