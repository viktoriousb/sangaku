import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import sangaku

/// Locates resources of this test bundle.
private final class BundleToken {}
private let testBundle = Bundle(for: BundleToken.self)

@Suite("Formula corpus")
struct FormulaCorpusTests {
    struct Row: CustomStringConvertible {
        var style: MathStyle
        var tier: String
        var latex: String
        var description: String { latex }
    }

    static func rows() throws -> [Row] {
        let url = try #require(testBundle.url(forResource: "formulas", withExtension: "tsv"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { line in
                let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
                return Row(style: fields[0] == "display" ? .display : .inline, tier: fields[1], latex: fields[2])
            }
    }

    static func context() throws -> MathContext {
        let url = try #require(testBundle.url(forResource: "corpus-preamble", withExtension: "tex"))
        let preamble = try String(contentsOf: url, encoding: .utf8)
        return MathContext(macros: MacroSet(MacroParser.parse(preamble).definitions))
    }

    @Test("Every formula lands in its recorded tier; unsupported ones are listed, and a listed one that starts rendering fails")
    func recordedTiers() throws {
        let renderer = MathRenderer.standard()
        let context = try Self.context()
        let rows = try Self.rows()
        #expect(rows.count >= 79)
        for row in rows {
            let rendered = renderer.render(row.latex, context: context, style: row.style)
            if rendered.tierName != row.tier {
                var detail = ""
                if case .source(let chip) = rendered { detail = " (\(chip.message))" }
                Issue.record("\(row.latex): expected \(row.tier), got \(rendered.tierName)\(detail)")
            }
        }
    }

    @Test("Every symbol, Greek letter and operator name in tier 1's tables is set by tier 1")
    func generatedTierOneSets() {
        let renderer = MathRenderer.standard()
        var names = Array(TypographicMath.symbols.keys) + Array(TypographicMath.greek.keys) + Array(TypographicMath.operatorNames)
        names.sort()
        for name in names {
            let tex = "a \\\(name) b"
            #expect(renderer.render(tex, context: MathContext(), style: .inline).tierName == "typographic", "\(tex)")
        }
    }

    @Test("Every command the validator knows renders with its arguments, through some tier, never as source")
    func generatedArgumentCommands() {
        let renderer = MathRenderer.standard()
        let unsupported: Set<String> = ["genfrac", "mathring"] // MicroTeX does not implement these
        for (name, arity) in TeXValidator.arity.sorted(by: { $0.key < $1.key }) where !unsupported.contains(name) {
            let arguments = name == "color" ? "{red}x" : name == "textcolor" ? "{red}{x}"
                : String(repeating: "{x}", count: arity)
            let tex = "\\\(name)\(arguments)"
            let rendered = renderer.render(tex, context: MathContext(), style: .inline)
            if case .source(let chip) = rendered { Issue.record("\(tex): \(chip.message)") }
        }
    }
}

@Suite("Fixture")
struct FixtureTests {
    private let fixture = PreviewFixtures.make()

    private func status(_ statement: Statement) -> StatementStatus {
        StatusRules.ownStatus(StatusInputs.make(for: statement, people: fixture.state.problems.personIDs()))
    }

    @Test("The example from the mockups: A has 6 steps, B has 5, and 4 of A's 6 are checked by a person")
    func shape() {
        #expect(fixture.attemptA.sortedSteps.count == 6)
        #expect(fixture.attemptB.sortedSteps.count == 5)
        let inputs = StatusInputs.make(for: fixture.theorem, people: fixture.state.problems.personIDs())
        #expect(inputs.sourceSteps.filter { $0.checkedOnCurrentRevision && !$0.hasOpenObjection }.count == 4)
        #expect(fixture.problem.sortedBranches.map(\.state) == [.live, .deadEnd, .deadEnd, .parked])
    }

    @Test("Invariant 8: the example's review reads 4 of 6, with step 5's objection open and step 6 checked by C only")
    func reviewState() {
        let review = AttemptReviewState.read(attempt: fixture.attemptA, people: fixture.state.problems.personIDs())
        #expect(review.progress.headline == "4 of 6 steps checked by a person")
        #expect(review.progress.notes == ["1 with an open objection"])
        #expect(!review.progress.isComplete)
        #expect(review.steps.map(\.standing.human) == [.checked, .checked, .checked, .checked, .objected, .unchecked])
        let referee = fixture.slotC.stableID
        #expect(review.steps.map(\.standing.model) == [
            .complete(referee: referee), .complete(referee: referee), .revisedSince(referee: referee),
            .complete(referee: referee), .revisedSince(referee: referee), .complete(referee: referee),
        ])
        #expect(review.steps[2].provenance.versions.map(\.author)
                == [.model(fixture.slotA.slotID), .human(fixture.you.personID)])
        #expect(review.steps[4].comments.map(\.body).last == "Does the parity argument close it?")
        #expect(review.steps.allSatisfy { $0.standing.recheck == nil })
    }

    @Test("Derived statuses follow the rules")
    func statuses() {
        // Steps 3 and 5 were revised after the referee's pass, so Thm 1 and Lem 3 rest on text it never saw.
        #expect(fixture.state.graph.state(for: fixture.problem).pinned?.derived.displayed == .sketched)
        #expect(fixture.lemmas.map(status) == [.formallyVerified, .humanChecked, .sketched, .modelChecked])
        #expect(status(fixture.refutedClaim) == .refuted)
        #expect(status(fixture.conjecture) == .proposed)
    }

    @Test("Invariant 1: a review written under a model's ID grants nothing")
    func modelsCannotGrantTrust() {
        let lemma4 = fixture.lemmas[3]
        let step6 = fixture.attemptA.sortedSteps[5]
        step6.reviews = (step6.reviews ?? []) + [Review(reviewer: PersonID(fixture.slotC.stableID), verdict: .correct,
                                                        revisionReviewedID: step6.latestRevision?.stableID)]
        #expect(status(lemma4) == .modelChecked)
    }

    @Test("Invariant 2: a new revision makes a checked step unchecked again")
    func editsResetReview() {
        let lemma2 = fixture.lemmas[1]
        #expect(status(lemma2) == .humanChecked)
        let step2 = fixture.attemptA.sortedSteps[1]
        let revision = StepRevision(author: .model(fixture.slotA.slotID), textLaTeX: step2.textLaTeX + " (reworded)",
                                    establishes: step2.establishes)
        revision.createdAt = Date.now.addingTimeInterval(3_600)
        step2.revisions = (step2.revisions ?? []) + [revision]
        #expect(status(lemma2) == .sketched, "unchecked, and newer than the referee's verdict")
    }

    @Test("Invariant 2: a person's revision resets review too")
    func personEditsResetReview() {
        let lemma2 = fixture.lemmas[1]
        let step2 = fixture.attemptA.sortedSteps[1]
        let revision = StepRevision(author: .human(fixture.mk.personID), textLaTeX: step2.textLaTeX + " (reworded)",
                                    establishes: step2.establishes)
        revision.createdAt = Date.now.addingTimeInterval(3_600)
        step2.revisions = (step2.revisions ?? []) + [revision]
        #expect(status(lemma2) == .sketched)
    }

    @Test("Invariant 11: an open ? blocks a ✓ until a person dismisses it")
    func objectionsBlockUntilDismissed() {
        let lemma3 = fixture.lemmas[2]
        let step5 = fixture.attemptA.sortedSteps[4]
        let current = step5.latestRevision?.stableID
        step5.reviews = (step5.reviews ?? []) + [Review(reviewer: fixture.you.personID, verdict: .correct, revisionReviewedID: current)]
        #expect(status(lemma3) == .sketched)
        let objection = (step5.reviews ?? []).first { $0.verdict == .unclear }
        objection?.dismissalReason = "The parity argument now spells it out."
        objection?.dismissedByID = fixture.you.stableID
        #expect(status(lemma3) == .humanChecked)
    }

    @Test("Invariant 1 and 11: a dismissal counts only from a person, with a reason")
    func dismissalsNeedAPersonAndAReason() {
        let lemma3 = fixture.lemmas[2]
        let step5 = fixture.attemptA.sortedSteps[4]
        step5.reviews = (step5.reviews ?? []) + [Review(reviewer: fixture.you.personID, verdict: .correct,
                                                        revisionReviewedID: step5.latestRevision?.stableID)]
        let objection = (step5.reviews ?? []).first { $0.verdict == .unclear }
        objection?.dismissedByID = fixture.slotC.stableID          // a model
        objection?.dismissalReason = "Looks fine to me."
        #expect(status(lemma3) == .sketched)
        objection?.dismissedByID = fixture.you.stableID            // a person, but no reason
        objection?.dismissalReason = "  "
        #expect(status(lemma3) == .sketched)
        objection?.dismissalReason = "Spelled out now."
        #expect(status(lemma3) == .humanChecked)
    }

    @Test("Invariant 11: an objection keeps blocking after its reviewer's record is deleted")
    func objectionsOutliveTheirReviewer() throws {
        let lemma3 = fixture.lemmas[2]
        let step5 = fixture.attemptA.sortedSteps[4]
        let objection = try #require((step5.reviews ?? []).first { $0.verdict == .unclear })
        objection.reviewerID = UUID()                               // nobody we know any more
        step5.reviews = (step5.reviews ?? []) + [Review(reviewer: fixture.mk.personID, verdict: .correct,
                                                        revisionReviewedID: step5.latestRevision?.stableID)]
        #expect(status(lemma3) == .sketched)
    }

    @Test("Invariant 12: a Lean result counts only if it ran, its messages are readable and fidelity is current")
    func leanMustHaveRun() throws {
        let lemma1 = fixture.lemmas[0]
        let lean = try #require(lemma1.leanResult)
        #expect(status(lemma1) == .formallyVerified)

        lean.checkedAt = nil
        #expect(status(lemma1) != .formallyVerified)
        lean.checkedAt = Date.now

        lean.messagesJSON = Data("not json".utf8)
        #expect(status(lemma1) != .formallyVerified)
        lean.messagesJSON = nil

        lean.leanStatementSource += " -- changed"
        #expect(status(lemma1) != .formallyVerified, "fidelity was given for the old statement")
    }

    @Test("Invariant 1: a fidelity review or a refutation acceptance under a model's ID counts for nothing")
    func modelsCannotConfirmFidelityOrRefutations() throws {
        let lemma2 = fixture.lemmas[1]
        let lean = try #require(lemma2.leanResult)
        lemma2.fidelityReviews = [FidelityReview(reviewer: PersonID(fixture.slotA.stableID),
                                                 leanStatementSource: lean.leanStatementSource, verdict: .matches)]
        #expect(status(lemma2) == .humanChecked)
        fixture.conjecture.refutationAcceptedByID = fixture.slotB.stableID
        #expect(status(fixture.conjecture) == .proposed)
    }

    @Test("Invariant 6: model citations are unverified until checked; the invented one is not found")
    func citations() {
        let citations = fixture.attemptA.sortedSteps.flatMap { $0.citations ?? [] }
        #expect(citations.map(\.status) == [.found, .notFound])
    }

    @Test("All of the fixture's math renders without source chips")
    func fixtureProseRenders() {
        let renderer = fixture.state.renderer
        let context = fixture.mathContext
        let texts = (fixture.attemptA.sortedSteps + fixture.attemptB.sortedSteps).map(\.textLaTeX)
            + [fixture.problem.statementLaTeX, fixture.problem.title]
            + (fixture.problem.statements ?? []).map(\.statementLaTeX)
            + fixture.problem.sortedNotation.flatMap { ["$\($0.symbolLaTeX)$", $0.meaning] }
            + [fixture.question, fixture.reply, fixture.interruptedReply, fixture.refereeMessage].map(\.bodyLaTeX)
            + (fixture.fanOut.verdicts ?? []).map(\.rationale)
        for text in texts {
            let composed = MathTextComposer.compose(text, renderer: renderer, context: context)
            #expect(composed.problems.isEmpty, "\(text): \(composed.problems.map(\.message))")
        }
    }
}

@Suite("Preview smoke tests")
struct PreviewSmokeTests {
    private let fixture = PreviewFixtures.make()

    /// Renders a view offscreen with the fixture's environment. With `SANGAKU_PREVIEW_DIR` set (pass
    /// `TEST_RUNNER_SANGAKU_PREVIEW_DIR` to xcodebuild), also writes it as a PNG for a visual check.
    private func render(_ name: String, width: Double, @ViewBuilder _ view: () -> some View) throws {
        let content = view()
            .environment(\.mathRenderer, fixture.state.renderer)
            .environment(\.problemManager, fixture.state.problems)
            .environment(\.saveScheduler, fixture.state.saves)
            .environment(\.threadManager, fixture.state.threads)
            .environment(\.statementGraph, fixture.state.graph)
            .environment(\.reviewManager, fixture.state.reviews)
            .environment(\.credentialManager, fixture.state.credentials)
            .environment(\.mathContext, fixture.mathContext)
            .modelContainer(fixture.state.container)
            .frame(width: width)
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "\(name) did not render")
        #expect(image.width > 0 && image.height > 0)
        if let folder = ProcessInfo.processInfo.environment["SANGAKU_PREVIEW_DIR"] {
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try data?.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
        }
    }

    @Test func pinnedProblemCard() throws {
        try render("pinned-problem", width: 760) { PinnedProblemCard(problem: fixture.problem, onEdit: {}) }
    }

    @Test func proofStepsThroughMathText() throws {
        try render("proof-steps", width: 640) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(fixture.attemptA.sortedSteps + fixture.attemptB.sortedSteps) { step in
                    MathText("\(step.index). " + step.textLaTeX)
                }
                MathText(#"Display: $$\sum_{k=0}^{n} \binom{n}{k} = 2^n$$ and a broken one: $\frac{a$."#)
            }
        }
    }

    @Test func statusLegendAndBadges() throws {
        try render("status", width: 360) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(StatementStatus.allCases, id: \.self) { StatusBadge(style: StatusStyle.style(for: $0)) }
                StatusLegend()
            }
        }
    }

    @Test func inspectorPanel() throws {
        let window = WindowState()
        window.select(problem: fixture.problem)
        window.selectedNodeID = fixture.cappedLemma.stableID
        try render("inspector", width: WindowRoot.inspectorWidth) { InspectorContent(window: window) }
        window.selectedNodeID = fixture.belowRefuted.stableID
        try render("inspector-dark", width: WindowRoot.inspectorWidth) {
            InspectorContent(window: window)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
        }
    }

    @Test func promoteSheet() throws {
        let target = PromotionTarget(attemptIDs: [fixture.attemptA.stableID, fixture.attemptB.stableID],
                                     stepID: fixture.attemptA.sortedSteps[3].stableID)
        try render("promote", width: 560) {
            PromoteSheet(problem: fixture.problem, target: target) { _ in }
        }
    }

    @Test func statementEditor() throws {
        let state = fixture.state.graph.state(for: fixture.problem)
        let lemma = try #require(state[fixture.onRefutedClaim.stableID])
        let theorem = try #require(state.pinned)
        try render("statement-editor", width: 520) { StatementEditor(problem: fixture.problem, node: lemma) }
        try render("statement-editor-theorem", width: 520) { StatementEditor(problem: fixture.problem, node: theorem) }
    }

    @Test func review() throws {
        let window = WindowState()
        window.select(problem: fixture.problem)
        window.activeView = .review
        window.reviewStepID = fixture.attemptA.sortedSteps[4].stableID
        // A ScrollView renders blank offscreen, so the page is drawn here from its parts; ReviewView itself is only
        // checked to render.
        try render("review", width: 900) {
            ReviewView(problem: fixture.problem, window: window).frame(height: 600)
        }
        let authors = AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
        let state = fixture.state.reviews.state(of: fixture.attemptA)
        let graph = fixture.state.graph.state(for: fixture.problem)
        let options = ReviewAttemptOption.make(messages: fixture.mainBranch.sortedMessages, live: [])
        for (name, scheme) in [("review-page", ColorScheme.light), ("review-page-dark", .dark)] {
            try render(name, width: 860) {
                VStack(alignment: .leading, spacing: 18) {
                    ReviewHeader(theorem: graph.pinned, options: options, chosen: state.attemptID, progress: state.progress,
                                 legend: [authors.mark(of: .model(fixture.slotA.slotID)), authors.mark(of: .human(fixture.you.personID))],
                                 authors: authors, onChoose: { _ in }, onClearHighlight: {})
                    ReviewRowsHost(state: state, authors: authors, current: fixture.attemptA.sortedSteps[4].stableID)
                }
                .padding(24)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            }
        }
        window.openReview(statement: try #require(graph[fixture.lemmas[2].stableID]))
        #expect(window.activeView == .review && window.review.highlightedStatementID == fixture.lemmas[2].stableID)
        try render("review-highlight", width: 640) {
            ReviewView(problem: fixture.problem, window: window).frame(height: 400)
        }
        let empty = fixture.state.problems.createProblem(title: "Empty")
        try render("review-empty", width: 640) {
            ReviewView(problem: empty, window: WindowState()).frame(height: 400)
        }
    }

    @Test func reviewRowsAndSheets() throws {
        let authors = AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
        let reviews = fixture.state.reviews
        let steps = fixture.attemptA.sortedSteps
        // A re-check flag, a withdrawn ✓, a dismissed objection and a comment, beside the example's states.
        try reviews.revise(steps[1].stableID, from: steps[1].latestRevision!.stableID, text: steps[1].textLaTeX,
                           establishes: "q > p and q odd")
        try reviews.mark(.wrong, step: steps[5].stableID, revision: steps[5].latestRevision!.stableID)
        let state = reviews.state(of: fixture.attemptA)
        try render("review-rows", width: 640) {
            ReviewRowsHost(state: state, authors: authors, current: steps[4].stableID)
        }
        try render("review-rows-narrow", width: 252) {
            ReviewRowsHost(state: state, authors: authors, current: steps[5].stableID)
        }
        let step5 = try #require(state[step: steps[4].stableID])
        try render("revise-sheet", width: 540) { ReviseSheet(step: step5, authors: authors) }
        let objection = try #require(step5.standing.openObjections.first)
        try render("dismiss-sheet", width: 460) { DismissSheet(step: step5, objection: objection, authors: authors) }
    }

    @Test func thread() throws {
        try render("thread", width: 900) {
            ThreadView(problem: fixture.problem, window: WindowState())
                .frame(height: 1100)
        }
    }

    @Test func messageRowsInEveryState() throws {
        let authors = AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
        let live = MessageStream()
        live.apply(.thinking)
        live.apply(.text(#"Step 1. By Sylow, $n_p \equiv 1 \pmod{p}$ and $n_q"#))
        try render("message-rows", width: 760) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach([fixture.question, fixture.reply, fixture.interruptedReply, fixture.failedReply]) { message in
                    MessageRow(message: message, stream: nil, authors: authors, onViewContext: { _ in }, onStop: {})
                }
                MessageRow(message: fixture.reply, stream: live, authors: authors, onViewContext: { _ in }, onStop: {})
            }
        }
    }

    @Test func messageRowsInDarkMode() throws {
        let authors = AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
        try render("message-rows-dark", width: 760) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach([fixture.question, fixture.reply]) { message in
                    MessageRow(message: message, stream: nil, authors: authors, onViewContext: { _ in }, onStop: {})
                }
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        }
    }

    @Test func composer() throws {
        try render("composer", width: 860) { Composer(problem: fixture.problem, branch: fixture.mainBranch) }
        let draft = fixture.state.threads.draft(for: fixture.mainBranch.stableID)
        draft.selection = SendSelection(recipients: [fixture.slotA.stableID, fixture.slotB.stableID], visibility: .shared,
                                        refereeSlotID: fixture.slotC.stableID)
        try render("composer-fan-out", width: 860) { Composer(problem: fixture.problem, branch: fixture.mainBranch) }
        try render("recipients-narrow", width: 252) { RecipientControls(problem: fixture.problem, draft: draft) }
    }

    private func threadContext() -> (items: [ThreadItem], context: ThreadContext) {
        let messages = fixture.mainBranch.sortedMessages
        let items = ThreadItem.make(messages)
        return (items, ThreadContext(
            problem: fixture.problem, branch: fixture.mainBranch, items: items, messages: messages, live: [:], runs: [:],
            notices: [:], authors: AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard),
            busy: false))
    }

    @Test func fanOutAndReferee() throws {
        let (items, context) = threadContext()
        for (name, width) in [("fan-out", 860.0), ("fan-out-narrow", 300.0)] {
            try render(name, width: width) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items.prefix(2)) { ThreadItemView(item: $0, context: context, onViewContext: { _ in }) }
                }
            }
        }
    }

    @Test func attemptCardsInEveryState() throws {
        let authors = AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
        let writing = MessageStream()
        writing.apply(.thinking)
        writing.apply(.text(String(DemoTransport.soundAttempt.prefix(500))))
        let waiting = MessageStream(phase: .queued)
        let unread = Message(author: .model(fixture.slotB.slotID), bodyLaTeX: #"{"overview":"x","steps":[{"text":"$\theta$"#, kind: .attempt)
        unread.request = RequestRecord()
        unread.request?.parseState = .unstructured
        unread.request?.stopReason = "stopped"
        unread.request?.finishedAt = .now
        unread.proofAttempt = ProofAttempt()
        try render("attempt-cards", width: 560) {
            EqualColumnsLayout {
                AttemptCard(message: fixture.messageA, stream: writing, authors: authors, onViewContext: { _ in }, onStop: {})
                AttemptCard(message: fixture.messageB, stream: waiting, authors: authors, onViewContext: { _ in }, onStop: {})
                AttemptCard(message: unread, stream: nil, authors: authors, onViewContext: { _ in }, onStop: {})
                AttemptCard(message: fixture.messageB, stream: nil, authors: authors, onViewContext: { _ in }, onStop: {})
            }
        }
    }

    @Test func contextSheetAndSettings() throws {
        let record = try #require(fixture.reply.request)
        try render("context-sheet", width: 720) { RequestContextSheet(record: record) }
        try render("settings", width: 480) { SettingsView() }
    }

    @Test func sheets() throws {
        try render("convention-editor", width: 520) { ConventionEditor(problem: fixture.problem, target: .add) }
        try render("preamble-import", width: 600) { PreambleImportSheet(problem: fixture.problem) }
        try render("problem-editor", width: 640) { ProblemEditor(problem: fixture.problem) }
    }
}

/// Review rows outside Review, with the focus state they take.
private struct ReviewRowsHost: View {
    let state: AttemptReviewState
    let authors: AuthorDirectory
    let current: UUID?

    @FocusState private var focus: ReviewFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(state.steps) { step in
                ReviewStepRow(step: step, authors: authors, isCurrent: step.id == current,
                              notice: step.id == current
                                  ? ReviewRowNotice(message: "Step \(step.index) flagged as unclear", isError: false, canUndo: true)
                                  : nil,
                              focus: $focus)
            }
        }
    }
}
