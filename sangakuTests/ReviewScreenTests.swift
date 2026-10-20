import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import sangaku

@Suite("Review keys: never while typing")
struct ReviewKeysTests {
    private func command(_ characters: String, typing: Bool = false, command: Bool = false, option: Bool = false,
                         control: Bool = false, shift: Bool = false) -> ReviewCommand? {
        ReviewKeys.command(for: ListKeyInput(characters: characters, command: command, option: option,
                                               control: control, shift: shift), isTyping: typing)
    }

    @Test("J, K, 1, 2, 3 and C, with caps lock too")
    func commands() {
        #expect(command("j") == .next && command("k") == .previous && command("c") == .comment)
        #expect(command("1") == .mark(.correct) && command("2") == .mark(.wrong) && command("3") == .mark(.unclear))
        #expect(command("J") == .next && command("C") == .comment, "caps lock is not a modifier")
        for other in ["x", "4", "0", " ", "jk", "", "\r"] { #expect(command(other) == nil, "\(other)") }
    }

    @Test("Any modifier, or a text field with the keyboard, gives nothing: ⌘-shortcuts and typing pass through")
    func neverIntercepts() {
        for key in ["j", "k", "1", "2", "3", "c"] {
            #expect(command(key, typing: true) == nil)
            #expect(command(key, command: true) == nil)
            #expect(command(key, option: true) == nil)
            #expect(command(key, control: true) == nil)
            #expect(command(key, shift: true) == nil)
        }
    }

    @Test("A held key repeats J and K only, so a held 1, 2 or 3 marks once; the list listens for both cases")
    func repeats() {
        func held(_ key: String) -> ReviewCommand? {
            ReviewKeys.command(for: ListKeyInput(characters: key, isRepeat: true), isTyping: false)
        }
        #expect(held("j") == .next && held("k") == .previous)
        for key in ["1", "2", "3", "c"] { #expect(held(key) == nil, "\(key)") }
        for key in ["j", "J", "k", "K", "1", "2", "3", "c", "C"] {
            #expect(key.unicodeScalars.allSatisfy(ReviewKeys.characters.contains), "\(key)")
        }
        #expect(!"x".unicodeScalars.allSatisfy(ReviewKeys.characters.contains))
    }

    @Test("A text view or field editor with the keyboard counts as typing")
    func textEditingProbe() {
        #expect(TextEditingProbe.isTyping(firstResponder: NSTextView()))
        #expect(!TextEditingProbe.isTyping(firstResponder: NSView()))
        #expect(!TextEditingProbe.isTyping(firstResponder: nil))
    }

    @Test("J and K stop at the ends; with no current step J starts at the first and K at the last")
    func navigation() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(ReviewNavigation.move(.next, from: nil, in: ids) == ids[0])
        #expect(ReviewNavigation.move(.previous, from: nil, in: ids) == ids[2])
        #expect(ReviewNavigation.move(.next, from: ids[0], in: ids) == ids[1])
        #expect(ReviewNavigation.move(.next, from: ids[2], in: ids) == ids[2])
        #expect(ReviewNavigation.move(.previous, from: ids[0], in: ids) == ids[0])
        #expect(ReviewNavigation.move(.next, from: UUID(), in: ids) == ids[0], "a step no longer listed")
        #expect(ReviewNavigation.move(.next, from: nil, in: [UUID]()) == nil)
        #expect(ReviewNavigation.move(.mark(.correct), from: ids[1], in: ids) == ids[1])
    }
}

@Suite("Which attempt Review shows")
struct ReviewAttemptChoiceTests {
    private func option(_ minute: Double, _ outcome: RefereeOutcome? = nil) -> AttemptOption {
        AttemptOption(id: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: minute * 60),
                            author: nil, stepCount: 3, isPartial: false, standingOutcome: outcome)
    }

    @Test("A pick by hand while offered; else the referee's attempts, complete first; else the theorem's; else the newest refereed; else the newest")
    func rule() {
        let old = option(1, .gap), complete = option(2, .complete), unrefereed = option(3), newest = option(4)
        let options = [old, complete, unrefereed, newest]
        func resolve(_ selection: ReviewSelection, theorem: UUID? = nil, among: [AttemptOption]? = nil) -> UUID? {
            ReviewAttemptChoice.resolve(selection, among: among ?? options, theoremSourceAttemptID: theorem)
        }
        #expect(resolve(ReviewSelection(attemptID: unrefereed.id)) == unrefereed.id)
        #expect(resolve(ReviewSelection(attemptID: UUID(), candidateAttemptIDs: [old.id])) == old.id,
                "a pick no longer offered falls back")
        #expect(resolve(ReviewSelection(candidateAttemptIDs: [old.id, complete.id])) == complete.id)
        #expect(resolve(ReviewSelection(candidateAttemptIDs: [old.id, unrefereed.id])) == old.id)
        #expect(resolve(ReviewSelection(), theorem: unrefereed.id) == unrefereed.id)
        #expect(resolve(ReviewSelection(), theorem: UUID()) == complete.id, "the newest refereed")
        #expect(resolve(ReviewSelection(), among: [unrefereed, newest]) == newest.id)
        #expect(resolve(ReviewSelection(), among: []) == nil)
    }

    @Test("The example's attempts are offered in order, with their verdicts; one still streaming is not")
    func options() throws {
        let fixture = PreviewFixtures.make()
        let messages = fixture.mainBranch.sortedMessages
        let options = AttemptOption.make(messages: messages, live: [])
        #expect(options.map(\.id) == [fixture.attemptA.stableID, fixture.attemptB.stableID])
        #expect(options.map(\.standingOutcome) == [.complete, .gap])
        #expect(options.map(\.stepCount) == [6, 5])
        #expect(AttemptOption.make(messages: messages, live: [fixture.messageB.stableID]).map(\.id)
                == [fixture.attemptA.stableID])
    }
}

@Suite("Window state for Review")
struct ReviewWindowStateTests {
    private let fixture = PreviewFixtures.make()

    @Test("Opening Review from a referee message, a step or a statement; a new problem starts over")
    func openReview() throws {
        let window = WindowState()
        window.select(problem: fixture.problem)
        let attempts = [fixture.attemptA.stableID, fixture.attemptB.stableID]
        window.openReview(ReviewTarget(attemptIDs: attempts))
        #expect(window.activeView == .review && window.review.candidateAttemptIDs == attempts && window.reviewStepID == nil)
        let step = fixture.attemptB.sortedSteps[4].stableID
        window.openReview(ReviewTarget(attemptIDs: [fixture.attemptB.stableID], stepID: step))
        #expect(window.reviewStepID == step && window.review.highlightedStatementID == nil)

        let lemma3 = try #require(fixture.state.graph.state(for: fixture.problem)[fixture.lemmas[2].stableID])
        window.activeView = .thread
        window.openReview(statement: lemma3)
        #expect(window.activeView == .review)
        #expect(window.review.candidateAttemptIDs == [fixture.attemptA.stableID])
        #expect(window.reviewStepID == fixture.attemptA.sortedSteps[2].stableID, "its first source step")
        #expect(window.review.highlightedStatementID == lemma3.id)
        window.clearReviewHighlight()
        #expect(window.review.highlightedStatementID == nil && window.reviewStepID != nil)

        window.chooseReview(attempt: fixture.attemptB.stableID)
        #expect(window.review.attemptID == fixture.attemptB.stableID && window.reviewStepID == nil)
        window.select(problem: fixture.problem)
        #expect(window.review == ReviewSelection() && window.reviewStepID == nil)
        #expect(window.selectedBranch(in: fixture.problem) === fixture.mainBranch)
    }

    @Test("A statement with no source steps opens nothing")
    func noSources() throws {
        let window = WindowState()
        let conjecture = try #require(fixture.state.graph.state(for: fixture.problem)[fixture.conjecture.stableID])
        window.openReview(statement: conjecture)
        #expect(window.activeView == .thread && window.review == ReviewSelection())
    }
}

@Suite("Review styles (invariant 3)")
struct StepReviewStyleTests {
    private var styles: [StatusStyle] {
        [StepReviewStyle.unchecked, StepReviewStyle.checked("MK · 11:04"),
         StepReviewStyle.objection(.wrong, by: "You"), StepReviewStyle.objection(.unclear, by: "You"),
         StepReviewStyle.model(.complete(referee: nil), referee: "C", personChecked: false)!,
         StepReviewStyle.model(.gapListed(referee: nil), referee: "C", personChecked: false)!,
         StepReviewStyle.model(.revisedSince(referee: nil), referee: "C", personChecked: false)!]
    }

    @Test("No two standings differ only by colour")
    func distinctWithoutColour() {
        let styles = styles
        for (i, a) in styles.enumerated() {
            for b in styles[(i + 1)...] {
                #expect(a.glyph != b.glyph || a.label != b.label || a.border != b.border, "\(a.label) / \(b.label)")
            }
        }
        #expect(Set(styles.map(\.glyph)).count == styles.count)
    }

    @Test("Unchecked math stays provisional; an objection is never drawn as a refutation")
    func provisional() {
        #expect(StepReviewStyle.unchecked.isProvisional && StepReviewStyle.unchecked.ink == .secondaryInk)
        #expect(!StepReviewStyle.checked("You").isProvisional)
        let refuted = StatusStyle.style(for: .refuted).label
        #expect(StepReviewStyle.objection(.wrong, by: "You").label != refuted)
        #expect(StepReviewStyle.objection(.wrong, by: "You").fill == nil)
        #expect(StepReviewStyle.model(.noVerdict, referee: "C", personChecked: false) == nil)
        #expect(StepReviewStyle.model(.complete(referee: nil), referee: "C", personChecked: true)?.label == "Also checked by C")
    }

    @Test("A row is drawn in full ink with an ink border only when a person's ✓ counts")
    func rows() {
        let check = ReviewFact(id: UUID(), createdAt: .now, reviewerID: UUID(), verdict: .correct, revisionID: UUID())
        var checked = StepStanding(id: UUID(), index: 1)
        checked.checks = [check]
        let checkedRow = StepReviewStyle.row(checked)
        #expect(checkedRow.ink == .ink && checkedRow.borderToken == .ink && checkedRow.border == .solid)
        #expect(!checkedRow.isProvisional)
        var wrong = checked
        wrong.openObjections = [ReviewFact(id: UUID(), createdAt: .now, reviewerID: nil, verdict: .wrong, revisionID: nil)]
        var unclear = checked
        unclear.openObjections = [ReviewFact(id: UUID(), createdAt: .now, reviewerID: nil, verdict: .unclear, revisionID: nil)]
        for standing in [StepStanding(id: UUID(), index: 1), wrong, unclear] {
            let row = StepReviewStyle.row(standing)
            #expect(row.isProvisional && row.ink == .secondaryInk && row.border != .solid)
        }
        #expect(StepReviewStyle.row(wrong).glyph == "✗" && StepReviewStyle.row(unclear).glyph == "?")
        #expect(StepReviewStyle.row(wrong).borderToken != StepReviewStyle.row(unclear).borderToken)
    }

    @Test("Invariant 7: the margin bar has a segment per author in version order, repeats merged")
    func provenanceSegments() {
        let fixture = PreviewFixtures.make()
        let authors = AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
        let a = Author.model(fixture.slotA.slotID), you = Author.human(fixture.you.personID)
        let versions = [a, a, you, a].enumerated().map { offset, author in
            RevisionFact(id: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: Double(offset)), author: author,
                         textLaTeX: "v\(offset)", establishes: "x")
        }
        let segments = ProvenanceBar.segments(StepProvenance(revisions: versions).versions, authors: authors)
        #expect(segments.map(\.text) == ["A", "You", "A"])
        #expect(segments.map(\.colorToken) == [.modelA, .ink, .modelA])
    }

    @Test("The re-check flag has its own glyph, distinct from every statement mark")
    func recheckGlyph() {
        let flag = StepReviewStyle.recheck(Recheck(causes: [.init(stepIndex: 2, revisionID: UUID(), at: .now)]))
        #expect(flag.glyph == StepReviewStyle.recheckGlyph)
        #expect(!StatusMark.allCases.map(\.glyph).contains(flag.glyph))
        #expect(!StatementStatus.allCases.map { StatusStyle.style(for: $0).glyph }.contains(flag.glyph))
        #expect(flag.label == "Re-check: step 2 changed what it establishes")
    }
}

/// Review rows outside Review, with the focus state they take.
private struct RowsHost: View {
    let state: AttemptReviewState
    let authors: AuthorDirectory
    let current: UUID?

    @FocusState private var focus: ReviewFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(state.steps) { step in
                ReviewStepRow(step: step, authors: authors, isCurrent: step.id == current, focus: $focus)
            }
        }
    }
}

@Suite("Review layout", .serialized)
struct ReviewLayoutTests {
    private let fixture = PreviewFixtures.make()

    private func environment<V: View>(_ view: V) -> some View {
        view
            .appEnvironment(fixture.state)
            .environment(\.mathContext, fixture.mathContext)
            .modelContainer(fixture.state.container)
    }

    private func size<V: View>(of view: V, width: CGFloat) -> CGSize {
        NSHostingController(rootView: environment(view))
            .sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }

    @Test("Every row, the current one with its objection, comments and actions included, fits the narrowest workspace")
    func rowsFit() throws {
        // Review pads its content by 24 on each side.
        let width = WindowRoot.contentMinWidth - 48
        let authors = AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
        let state = fixture.state.reviews.state(of: fixture.attemptA)
        for step in state.steps {
            let size = size(of: RowsHost(state: state, authors: authors, current: step.id), width: width)
            #expect(size.width <= width, "step \(step.index) current")
        }
        let graph = fixture.state.graph.state(for: fixture.problem)
        let header = ReviewHeader(theorem: graph.pinned, options: AttemptOption.make(messages: fixture.mainBranch.sortedMessages, live: []),
                                  chosen: state.attemptID, progress: state.progress,
                                  legend: [authors.mark(of: .model(fixture.slotA.slotID))], authors: authors,
                                  highlight: "Lem 3", onChoose: { _ in }, onClearHighlight: {})
        #expect(size(of: header, width: width).width <= width)
    }

    @Test("Offered no space at all, Review still fits a window of the minimum size")
    func minimumSize() {
        let window = WindowState()
        window.select(problem: fixture.problem)
        window.reviewStepID = fixture.attemptA.sortedSteps[4].stableID
        let size = NSHostingController(rootView: environment(ReviewView(problem: fixture.problem, window: window)))
            .sizeThatFits(in: .zero)
        #expect(size.width <= WindowRoot.contentMinWidth)
        #expect(size.height <= WindowRoot.minimumHeight - 52)
    }
}

@Suite("What Review says")
struct ReviewWordingTests {
    private let fixture = PreviewFixtures.make()
    private var authors: AuthorDirectory {
        AuthorDirectory(problem: fixture.problem, people: [fixture.you, fixture.mk], catalog: .standard)
    }
    private var state: AttemptReviewState { fixture.state.reviews.state(of: fixture.attemptA) }
    private func step(_ index: Int) -> StepReview { state.steps[index - 1] }

    @Test("Chips: who checked and when, open objections with who raised them, and the referee's word on this version")
    func chips() {
        func labels(_ index: Int) -> [String] { ReviewWording.chips(for: step(index), authors: authors).map(\.label) }
        let time = { (index: Int) in ShortTime.text(step(index).standing.latestCheckAt!) }
        #expect(labels(1) == ["You · \(time(1))", "Also checked by C"])
        #expect(labels(2) == ["MK · \(time(2))", "Also checked by C"])
        #expect(labels(3) == ["You · \(time(3))", "C's check covered an earlier version"])
        #expect(labels(5) == ["Unclear, open · You", "C's check covered an earlier version"])
        #expect(labels(6) == ["Not checked by a person", "Checked by C only"])
    }

    @Test("Provenance, objection, dismissal and history lines name people and versions")
    func lines() throws {
        let revisedAt = ShortTime.text(try #require(step(3).provenance.current).createdAt)
        #expect(ReviewWording.provenanceLine(step(3), authors: authors)
                == "Written by Model A, revised by You · \(revisedAt) (version 2)")
        #expect(ReviewWording.provenanceLine(step(1), authors: authors) == "Written by Model A")
        var objection = try #require(step(5).standing.openObjections.first)
        #expect(ReviewWording.objectionLine(objection, authors: authors)
                == "? Unclear, raised by You · \(ShortTime.text(objection.createdAt))")
        objection.dismissedByID = fixture.mk.stableID
        objection.dismissalReason = "The parity argument closes it."
        objection.dismissedAt = objection.createdAt
        #expect(ReviewWording.dismissalLine(objection, authors: authors)
                == "? Unclear by You, dismissed by MK · \(ShortTime.text(objection.createdAt)): The parity argument closes it.")
        let history = step(3).history.map { ReviewWording.historyLine($0, step: step(3), authors: authors) }
        #expect(history.first?.hasPrefix("✓ Correct by You") == true)
        #expect(history.contains { $0.hasPrefix("Version 2, current, by You") && $0.hasSuffix("text changed") })
        #expect(history.last?.hasPrefix("Version 1 by Model A") == true)
        #expect(ReviewWording.legend(state, authors: authors).map(\.name) == ["Model A", "You"])
    }

    @Test("A revision says what it resets before it is saved")
    func consequences() {
        let step1 = ReviewWording.revisionConsequences(step(1), establishes: step(1).establishes, authors: authors)
        #expect(step1.contains("Checks by You on this version stop counting."))
        #expect(step1.contains("C's check no longer covers the step."))
        #expect(!step1.contains("re-check"))
        let step5 = ReviewWording.revisionConsequences(step(5), establishes: "a new claim", authors: authors)
        #expect(step5.contains("Open objections on this version close."))
        #expect(!step5.contains("no longer covers"), "C's check already covers an earlier version only")
        #expect(step5.contains("later checked steps are flagged for re-check"))
    }

    @Test("Invariants 8 and 11: a ✓ beside an open objection is never announced as counting")
    func announcements() {
        let blocked = "Step 5: your check is recorded, but an open objection still blocks it"
        #expect(ReviewWording.announcement(.recorded(UUID()), verdict: .correct, step: step(5)) == blocked)
        #expect(ReviewWording.announcement(.alreadyChecked, verdict: .correct, step: step(5)) == blocked)
        #expect(ReviewWording.announcement(.recorded(UUID()), verdict: .correct, step: step(6)) == "Step 6 marked correct")
        #expect(ReviewWording.announcement(.alreadyChecked, verdict: .correct, step: step(1))
                == "Step 1: your check already counts")
        #expect(ReviewWording.announcement(.alreadyRaised, verdict: .unclear, step: step(5))
                == "Step 5: your unclear is already open")
        #expect(ReviewWording.announcement(.recorded(UUID()), verdict: .wrong, step: step(5)) == "Step 5 marked wrong")
    }

    @Test("A withdrawn objection says who withdrew it and that it no longer blocks")
    func withdrawals() throws {
        var objection = try #require(step(5).standing.openObjections.first)
        objection.withdrawnAt = objection.createdAt
        #expect(ReviewWording.withdrawalLine(objection, authors: authors)
                == "? Unclear by You, withdrawn · \(ShortTime.text(objection.createdAt))")
        #expect(ReviewWording.withdrawalAnnouncement(objection, step: step(5))
                == "Your unclear on step 5 withdrawn; it no longer blocks the step")
        let check = try #require(step(1).standing.checks.first)
        #expect(ReviewWording.withdrawalAnnouncement(check, step: step(1)) == "Your check on step 1 withdrawn")
    }

    @Test("A person whose record is gone is named the same way everywhere; the earliest \"me\" counts")
    func people() {
        let gone = UUID()
        #expect(authors.name(ofPerson: gone) == AuthorDirectory.missingPerson)
        #expect(authors.initials(ofPerson: gone) == AuthorDirectory.missingPerson)
        #expect(authors.name(of: .human(PersonID(gone))) == AuthorDirectory.missingPerson)
        #expect(authors.mark(of: .human(PersonID(gone))).name == AuthorDirectory.missingPerson)
        let later = Person(name: "Also me", initials: "AM", isMe: true)
        later.createdAt = fixture.you.createdAt.addingTimeInterval(60)
        #expect(Person.me(among: [later, fixture.mk, fixture.you]) === fixture.you)
        let directory = AuthorDirectory(problem: fixture.problem, people: [later, fixture.you], catalog: .standard)
        #expect(directory.meID == fixture.you.stableID)
        #expect(directory.mark(of: .human(later.personID)).colorToken == .coauthor)
    }
}
