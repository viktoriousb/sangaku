import AppKit
import Foundation
import Testing
@testable import sangaku

@Suite("Status style (invariant 3)")
struct StatusStyleTests {
    @Test("No two statuses differ only by colour")
    func distinctWithoutColour() {
        let styles = StatementStatus.allCases.map(StatusStyle.style(for:))
        #expect(Set(styles.map(\.glyph)).count == styles.count)
        #expect(Set(styles.map(\.label)).count == styles.count)
        #expect(styles.allSatisfy { !$0.glyph.isEmpty && !$0.label.isEmpty })
        let branches = BranchState.allCases.map(StatusStyle.style(for:))
        #expect(Set(branches.map(\.glyph)).count == branches.count)
    }

    @Test("Unchecked math looks provisional; only checked statuses draw in full ink")
    func provisionalInk() {
        for status in StatementStatus.allCases {
            let style = StatusStyle.style(for: status)
            let unchecked = [.proposed, .sketched, .modelChecked, .imported].contains(status)
            #expect(style.isProvisional == unchecked, "\(status)")
            if unchecked { #expect(style.ink == .secondaryInk, "\(status)") }
        }
        #expect(StatusStyle.style(for: .proposed).border == .dotted)
        #expect(StatusStyle.style(for: .sketched).border == .dashed)
        #expect(StatusStyle.style(for: .humanChecked).border == .solid)
    }

    @Test("Differentiate Without Color shows labels; Increase Contrast widens borders")
    func accessibility() {
        let style = StatusStyle.style(for: .sketched)
        let plain = StatusPresentation(style: style, accessibility: StatusAccessibility())
        let adjusted = StatusPresentation(style: style, accessibility: StatusAccessibility(differentiateWithoutColor: true, increaseContrast: true))
        #expect(plain.showsGlyph && adjusted.showsGlyph)
        #expect(!plain.showsLabelInline && adjusted.showsLabelInline)
        #expect(adjusted.borderWidth > plain.borderWidth)
        #expect(!adjusted.dash.isEmpty)
    }

    @Test func everyColourTokenHasAnAsset() {
        for token in ColorToken.allCases {
            #expect(NSColor(named: token.rawValue) != nil, "\(token.rawValue) missing from Assets.xcassets")
        }
    }
}

@Suite("Status rules")
struct StatusRulesTests {
    private let checked = StatusInputs.SourceStep(checkedOnCurrentRevision: true, hasOpenObjection: false)
    private let goodLean = StatusInputs.Lean(ran: true, errorCount: 0, sorryCount: 0,
                                             axiomCheck: .ran(declaration: "Sangaku.S0.main", axioms: ["propext", "Quot.sound"]),
                                             fidelityConfirmed: true)

    @Test func precedence() {
        #expect(StatusRules.ownStatus(StatusInputs()) == .proposed)
        #expect(StatusRules.ownStatus(StatusInputs(sourceSteps: [checked], refereePassed: false)) == .humanChecked)
        var inputs = StatusInputs(lean: goodLean, sourceSteps: [checked], refereePassed: true)
        #expect(StatusRules.ownStatus(inputs) == .formallyVerified)
        inputs.refutationAccepted = true
        #expect(StatusRules.ownStatus(inputs) == .refuted)
        let unchecked = StatusInputs.SourceStep(checkedOnCurrentRevision: false, hasOpenObjection: false)
        #expect(StatusRules.ownStatus(StatusInputs(sourceSteps: [unchecked], refereePassed: true)) == .modelChecked)
        #expect(StatusRules.ownStatus(StatusInputs(sourceSteps: [unchecked])) == .sketched)
    }

    @Test("Invariant 12: Lean counts only with standard axioms and a person's fidelity check")
    func leanIsCheckedNotTrusted() {
        var lean = goodLean
        lean.axiomCheck = .ran(declaration: "Sangaku.S0.main", axioms: ["propext", "sorryAx"])
        #expect(StatusRules.ownStatus(StatusInputs(lean: lean)) == .proposed)
        lean.axiomCheck = .ran(declaration: "Sangaku.S0.main", axioms: ["Lean.ofReduceBool"])
        #expect(StatusRules.ownStatus(StatusInputs(lean: lean)) == .proposed)
        // "Does not depend on any axioms" counts, but only when the axiom line was read.
        lean.axiomCheck = .ran(declaration: "Sangaku.S0.main", axioms: [])
        #expect(StatusRules.ownStatus(StatusInputs(lean: lean)) == .formallyVerified)
        lean.axiomCheck = .notRun
        #expect(StatusRules.ownStatus(StatusInputs(lean: lean)) == .proposed, "an empty list from no check is not a result")
        lean = goodLean
        lean.fidelityConfirmed = false
        #expect(StatusRules.ownStatus(StatusInputs(lean: lean)) == .proposed)
        lean = goodLean
        lean.sorryCount = 1
        #expect(StatusRules.ownStatus(StatusInputs(lean: lean)) == .proposed)
        lean = goodLean
        lean.errorCount = 1
        #expect(StatusRules.ownStatus(StatusInputs(lean: lean)) == .proposed)
        lean = goodLean
        lean.ran = false
        #expect(StatusRules.ownStatus(StatusInputs(lean: lean)) == .proposed)
    }

    @Test("Invariant 11: an open objection blocks a person's check")
    func objectionsBlock() {
        let objected = StatusInputs.SourceStep(checkedOnCurrentRevision: true, hasOpenObjection: true)
        #expect(StatusRules.ownStatus(StatusInputs(sourceSteps: [checked, objected])) == .sketched)
    }
}

@Suite("Referee verdicts and rule 4")
struct RefereeVerdictRuleTests {
    private let earlier = Date(timeIntervalSinceReferenceDate: 1_000)
    private let later = Date(timeIntervalSinceReferenceDate: 2_000)

    /// Whether the verdicts pass every one of `steps`, each first written at `earlier`, through the per-step rule
    /// statuses read.
    private func passes(_ verdicts: [VerdictFact], steps: [Int]) -> Bool {
        let facts = steps.map { index in
            StepFact(id: UUID(), index: index, confidence: .standard, text: "", establishes: "",
                     revisions: [RevisionFact(id: UUID(), createdAt: earlier, author: nil, textLaTeX: "", establishes: "")])
        }
        let standings = StepStandings.derive(AttemptFact(id: UUID(), steps: facts, verdicts: verdicts), people: [])
        return !standings.isEmpty && standings.allSatisfy(\.model.passes)
    }

    @Test("Rule 4: the newest verdict on an attempt stands, a later gap over an earlier complete and the other way round")
    func newestWins() {
        let complete = VerdictFact(createdAt: earlier, outcome: .complete, gapStepIndices: [], requestedAt: earlier)
        let gap = VerdictFact(createdAt: later, outcome: .gap, gapStepIndices: [3], requestedAt: later)
        #expect(!passes([complete, gap], steps: [1, 2]), "the later gap overrides")
        let regained = VerdictFact(createdAt: later.addingTimeInterval(1), outcome: .complete, gapStepIndices: [],
                                   requestedAt: later)
        #expect(passes([complete, gap, regained], steps: [1, 2, 3]))
        #expect(!passes([], steps: [1]), "no verdict, no model check")
        #expect(!passes([regained], steps: []), "no steps, no model check")
    }

    @Test("Rule 4: verdicts given at the same instant stand together, so a tie is a gap")
    func tiesFailClosed() {
        let complete = VerdictFact(createdAt: later, outcome: .complete, gapStepIndices: [], requestedAt: earlier)
        let gap = VerdictFact(createdAt: later, outcome: .gap, gapStepIndices: [5], requestedAt: later)
        #expect(StatusRules.standingVerdict([complete, gap])
                    == VerdictFact(createdAt: later, outcome: .gap, gapStepIndices: [5], requestedAt: earlier))
        #expect(!passes([complete, gap], steps: [1]))
        let unknown = VerdictFact(createdAt: later, outcome: .complete, gapStepIndices: [])
        #expect(StatusRules.standingVerdict([complete, unknown])?.requestedAt == nil,
                "a tie with an unknown request time covers nothing")
    }

    @Test("Rule 4: a verdict covers a step's text only as it stood when the referee was asked")
    func revisedSince() {
        let complete = VerdictFact(createdAt: later, outcome: .complete, gapStepIndices: [], requestedAt: earlier)
        #expect(StatusRules.modelCheck(complete, stepIndex: 1, latestRevisionAt: earlier) == .complete(referee: nil),
                "a revision at the request time is covered")
        #expect(StatusRules.modelCheck(complete, stepIndex: 1, latestRevisionAt: earlier.addingTimeInterval(1))
                    == .revisedSince(referee: nil))
        #expect(StatusRules.modelCheck(complete, stepIndex: 1, latestRevisionAt: nil) == .revisedSince(referee: nil),
                "a step with no revision has no text the verdict saw")
        let unknown = VerdictFact(createdAt: later, outcome: .complete, gapStepIndices: [])
        #expect(StatusRules.modelCheck(unknown, stepIndex: 1, latestRevisionAt: earlier) == .unknownBasis(referee: nil))
        let gap = VerdictFact(createdAt: later, outcome: .gap, gapStepIndices: [2], requestedAt: later)
        #expect(StatusRules.modelCheck(gap, stepIndex: 2, latestRevisionAt: earlier) == .gapListed(referee: nil))
        #expect(StatusRules.modelCheck(gap, stepIndex: 1, latestRevisionAt: earlier) == .attemptHasGap(referee: nil))
        #expect(StatusRules.modelCheck(nil, stepIndex: 1, latestRevisionAt: earlier) == .noVerdict)
    }

    @Test("Invariant 1: a referee's verdict lifts a statement to checked by a model at most, and a newer gap takes it away")
    func verdictsNeverGrantPersonTrust() throws {
        let fixture = PreviewFixtures.make()
        let lemma3 = fixture.lemmas[2]
        func status() -> StatementStatus {
            StatusRules.ownStatus(StatusInputs.make(for: lemma3, people: fixture.state.problems.personIDs()))
        }
        #expect(status() == .sketched, "steps 3 and 5 were revised after the referee's pass")
        func add(_ verdict: RefereeVerdict, after seconds: TimeInterval) {
            verdict.createdAt = .now.addingTimeInterval(seconds)
            verdict.requestedAt = .now.addingTimeInterval(seconds - 60)
            verdict.attempt = fixture.attemptA
            fixture.fanOut.verdicts = (fixture.fanOut.verdicts ?? []) + [verdict]
        }
        add(RefereeVerdict(outcome: .complete, rationale: "The revisions hold up."), after: 1_800)
        #expect(status() == .modelChecked)
        add(RefereeVerdict(outcome: .gap, gapStepIndices: [4], rationale: "Step 4 is unjustified."), after: 3_600)
        #expect(status() == .sketched)
        let complete = RefereeVerdict(outcome: .complete, rationale: "Fine after all.")
        complete.createdAt = .now.addingTimeInterval(7_200)
        complete.requestedAt = .now.addingTimeInterval(7_100)
        complete.attempt = fixture.attemptA
        fixture.fanOut.verdicts = (fixture.fanOut.verdicts ?? []) + [complete]
        #expect(status() == .modelChecked, "a complete verdict never reaches humanChecked")
    }

    @Test("Rule 4 through the store: a stored verdict with no request time covers nothing, and neither does a tie with one")
    func storedVerdicts() throws {
        let fixture = PreviewFixtures.make()
        let lemma4 = fixture.lemmas[3]
        func status() -> StatementStatus {
            StatusRules.ownStatus(StatusInputs.make(for: lemma4, people: fixture.state.problems.personIDs()))
        }
        let verdictA = try #require(fixture.attemptA.verdicts?.first)
        #expect(status() == .modelChecked)
        let unknown = RefereeVerdict(outcome: .complete)
        unknown.createdAt = verdictA.createdAt
        unknown.attempt = fixture.attemptA
        fixture.fanOut.verdicts = (fixture.fanOut.verdicts ?? []) + [unknown]
        #expect(status() == .sketched, "tied with a verdict that records no request time")
        unknown.attempt = nil
        fixture.fanOut.verdicts = (fixture.fanOut.verdicts ?? []).filter { $0 !== unknown }
        #expect(status() == .modelChecked)
        verdictA.requestedAt = nil
        #expect(status() == .sketched, "a verdict from before request times were recorded")
    }

    @Test("Invariant 3: verdicts are told apart without colour; complete is a model's check, a gap is never refuted")
    func verdictStyles() {
        let styles = [RefereeOutcome.complete, .gap, nil].map(StatusStyle.style(for:))
        #expect(Set(styles.map(\.glyph)).count == 3 && Set(styles.map(\.label)).count == 3)
        #expect(Set(styles.map(\.border)).count == 3)
        let complete = StatusStyle.style(for: RefereeOutcome.complete)
        #expect(complete.borderToken == StatusStyle.style(for: .modelChecked).borderToken)
        #expect(complete.glyph == StatusStyle.style(for: .modelChecked).glyph)
        #expect(complete.borderToken != .verified && complete.fill != .verifiedFill)
        let gap = StatusStyle.style(for: RefereeOutcome.gap)
        #expect(gap.borderToken != .refuted && gap.fill != .refutedFill && gap.glyph != StatusStyle.style(for: .refuted).glyph)
        #expect(styles.allSatisfy { $0.isProvisional }, "a model's verdict is never a person's check")
        #expect(VerdictChip.text(letter: "B", outcome: .gap, gapSteps: [5], partial: true) == "B (partial): gap at step 5")
    }

    @Test("Invariant 10: a step's confidence label never changes its statement's status")
    func confidenceIsDisplayOnly() {
        let fixture = PreviewFixtures.make()
        let lemma2 = fixture.lemmas[1]
        let before = StatusRules.ownStatus(StatusInputs.make(for: lemma2, people: fixture.state.problems.personIDs()))
        for confidence in Confidence.allCases {
            fixture.attemptA.sortedSteps[1].confidence = confidence
            #expect(StatusRules.ownStatus(StatusInputs.make(for: lemma2, people: fixture.state.problems.personIDs())) == before)
        }
    }
}
