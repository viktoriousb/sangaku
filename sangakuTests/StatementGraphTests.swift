import Foundation
import Observation
import SwiftData
import Testing
@testable import sangaku

/// Set from an observation callback, which runs synchronously on the main thread during the change.
nonisolated private final class Signal: @unchecked Sendable {
    var fired = false
}

@Suite("Statement graph on the example (invariant 13)")
struct StatementGraphFixtureTests {
    private let fixture = PreviewFixtures.make()

    private var state: StatementGraphState { fixture.state.graph.state(for: fixture.problem) }

    @Test("Invariant 13: every statement of the example shows the lower of its own status and its dependencies'")
    func displayed() {
        let state = state
        let table = Dictionary(uniqueKeysWithValues: state.nodes.map { ($0.label, [$0.derived.own, $0.derived.displayed]) })
        #expect(table == [
            "Thm 1": [.sketched, .sketched],
            "Lem 1": [.formallyVerified, .formallyVerified],
            "Lem 2": [.humanChecked, .humanChecked],
            "Lem 3": [.sketched, .sketched],
            "Lem 4": [.modelChecked, .modelChecked],
            "Claim": [.refuted, .refuted],
            "Conj": [.proposed, .proposed],
            "Lem 5": [.formallyVerified, .sketched],
            "Lem 6": [.humanChecked, .sketched],
            "Lem 7": [.humanChecked, .sketched],
        ])
        #expect(state.nodes.first?.label == "Thm 1")
        #expect(state[fixture.cappedLemma.stableID]?.explanation.caps == "Capped by Lem 3 (sketched)")
        #expect(state[fixture.onRefutedClaim.stableID]?.explanation.refutedDependency == "Depends on a refuted claim: Claim")
        #expect(state[fixture.belowRefuted.stableID]?.explanation.refutedDependency
                == "Depends on a refuted claim through Lem 6")
    }

    @Test("Invariant 13: a refuted dependency shows on everything above it, and only a person refutes")
    func refutationPropagates() {
        let lemma4 = fixture.lemmas[3]
        lemma4.refutationAcceptedByID = fixture.slotA.stableID
        lemma4.refutationAcceptedAt = .now
        #expect(fixture.state.graph.state(for: fixture.problem).pinned?.derived.dependsOnRefuted == false,
                "a refutation accepted under a model's ID counts for nothing (invariant 1)")
        #expect(state[lemma4.stableID]?.derived.own == .modelChecked)
        lemma4.refutationAcceptedByID = fixture.you.stableID
        #expect(fixture.state.graph.state(for: fixture.problem).pinned?.derived.displayed == .sketched)
        let pinned = fixture.state.graph.state(for: fixture.problem).pinned
        #expect(pinned?.derived.dependsOnRefuted == true)
        #expect(pinned?.explanation.refutedDependency == "Depends on a refuted claim: Lem 4")
        let state = state
        #expect(state[fixture.cappedLemma.stableID]?.derived.displayed == .sketched)
        #expect(state[fixture.lemmas[2].stableID]?.derived.dependsOnRefuted == false, "Lem 3 does not use Lem 4")
    }

    @Test("Invariant 13: a theorem verified in Lean still shows no more than what it uses")
    func leanTheoremIsCapped() {
        fixture.theorem.recordLeanCheck(.trivial)
        fixture.theorem.confirmLean(by: fixture.you.personID)
        let pinned = fixture.state.graph.state(for: fixture.problem).pinned
        #expect(pinned?.derived.own == .formallyVerified)
        #expect(pinned?.derived.displayed == .sketched)
        #expect(pinned?.explanation.caps == "Capped by Lem 3 (sketched)")
    }

    @Test("A newer verdict raises or lowers everything resting on the attempt, with no other call")
    func newerVerdict() {
        // A second pass that saw the revised steps 3 and 5 covers them again.
        let complete = RefereeVerdict(outcome: .complete)
        complete.createdAt = .now.addingTimeInterval(1800)
        complete.requestedAt = .now
        fixture.state.container.mainContext.insert(complete)
        complete.attempt = fixture.attemptA
        #expect(state[fixture.lemmas[2].stableID]?.derived.displayed == .modelChecked)
        #expect(state.pinned?.derived.displayed == .modelChecked)
        #expect(state[fixture.cappedLemma.stableID]?.derived.displayed == .modelChecked)

        let verdict = RefereeVerdict(outcome: .gap, gapStepIndices: [5])
        verdict.requestedAt = .now
        verdict.createdAt = .now.addingTimeInterval(3600)
        fixture.state.container.mainContext.insert(verdict)
        verdict.attempt = fixture.attemptA
        let state = state
        #expect(state[fixture.lemmas[2].stableID]?.derived.displayed == .sketched)
        #expect(state.pinned?.derived.displayed == .sketched)
        #expect(state[fixture.cappedLemma.stableID]?.derived.displayed == .sketched)
    }

    /// Whether a view that read the graph would be asked to read it again after `change`.
    private func invalidates(_ change: () -> Void) -> Bool {
        let signal = Signal()
        let people = fixture.state.problems.personIDs()
        withObservationTracking {
            _ = StatementGraphState.read(problem: fixture.problem, people: people)
        } onChange: {
            signal.fired = true
        }
        change()
        return signal.fired
    }

    @Test("Views reading the graph are told about a new verdict, review, dismissal, edge or refutation")
    func observation() {
        let context = fixture.state.container.mainContext
        let step6 = fixture.attemptA.sortedSteps[5]
        #expect(invalidates {
            let verdict = RefereeVerdict(outcome: .gap, gapStepIndices: [5])
            context.insert(verdict)
            verdict.attempt = fixture.attemptA
        }, "a verdict linked from its own side")
        #expect(invalidates {
            let review = Review(reviewer: fixture.you.personID, verdict: .correct,
                                revisionReviewedID: step6.latestRevision?.stableID)
            context.insert(review)
            review.step = step6
        }, "a review linked from its own side")
        #expect(invalidates {
            let question = fixture.attemptA.sortedSteps[4].reviews?.first
            question?.dismissedByID = fixture.you.stableID
            question?.dismissalReason = "The parity argument closes it."
        }, "a dismissal")
        #expect(invalidates { fixture.cappedLemma.uses = [] }, "an edge")
        #expect(invalidates { fixture.conjecture.refutationAcceptedByID = fixture.you.stableID }, "a refutation")
    }
}

@Suite("Statement graph manager")
struct StatementGraphManagerTests {
    private let fixture = PreviewFixtures.make()

    private var graph: StatementGraph { fixture.state.graph }
    private var problem: Problem { fixture.problem }
    private var contextRevision: Int { fixture.state.problems.contextRevisions[problem.stableID, default: 0] }

    private func draft(_ attempt: ProofAttempt, _ first: Int, _ last: Int) -> PromotionDraft {
        PromotionDraft(attemptID: attempt.stableID, first: first, last: last,
                       existingLabels: (problem.statements ?? []).map(\.label),
                       texts: Dictionary(uniqueKeysWithValues: attempt.sortedSteps.map { ($0.index, $0.textLaTeX) }))
    }

    @Test("Invariant 1: promoting records the person, keeps the steps' authors and grants no status of its own")
    func promote() throws {
        let authors = fixture.attemptA.sortedSteps.map { ($0.revisions ?? []).map(\.author) }
        let revision = contextRevision
        var draft = draft(fixture.attemptA, 1, 2)
        draft.editText("If neither Sylow subgroup is normal, then $n_p = q$ and $q > p$.")
        draft.uses = [fixture.lemmas[0].stableID]
        let statement = try graph.promote(draft, in: problem)
        #expect(statement.label == "Lem 8")
        #expect(statement.kind == .lemma)
        #expect(statement.author == .human(fixture.you.personID))
        #expect(Set((statement.sourceSteps ?? []).map(\.index)) == [1, 2])
        #expect(statement.uses?.map(\.stableID) == [fixture.lemmas[0].stableID])
        #expect(fixture.theorem.uses?.contains { $0 === statement } == true, "used by the theorem unless switched off")
        #expect(fixture.attemptA.sortedSteps.map { ($0.revisions ?? []).map(\.author) } == authors)
        #expect(contextRevision == revision + 1, "the composer's estimate is rebuilt")
        #expect(graph.state(for: problem)[statement.stableID]?.derived.displayed == .humanChecked,
                "A·1 and A·2 carry a person's ✓; the status comes from them")
    }

    @Test("Invariant 13: steps a referee found a gap in make a sketched lemma, which caps the theorem using it")
    func promoteGap() throws {
        let statement = try graph.promote(draft(fixture.attemptB, 1, 4), in: problem)
        #expect(graph.state(for: problem)[statement.stableID]?.derived.displayed == .sketched)
        #expect(graph.state(for: problem).pinned?.derived.displayed == .sketched)
    }

    @Test("A refused promotion changes nothing")
    func promoteRefusals() {
        let count = problem.statements?.count
        let theoremUses = fixture.theorem.uses?.count
        let revision = contextRevision
        var blank = draft(fixture.attemptA, 1, 1)
        blank.editLabel("  ")
        #expect(throws: StatementError.emptyLabel) { try graph.promote(blank, in: problem) }
        var taken = draft(fixture.attemptA, 1, 1)
        taken.editLabel(" lem 3")
        #expect(throws: StatementError.duplicateLabel("lem 3")) { try graph.promote(taken, in: problem) }
        var empty = draft(fixture.attemptA, 1, 1)
        empty.editText(" ")
        #expect(throws: StatementError.emptyStatement) { try graph.promote(empty, in: problem) }
        var conjecture = draft(fixture.attemptA, 1, 1)
        conjecture.chooseKind(.conjecture, existingLabels: [])
        #expect(throws: StatementError.kindNotPromotable(.conjecture)) { try graph.promote(conjecture, in: problem) }
        var cycle = draft(fixture.attemptA, 1, 1)
        cycle.uses = [fixture.theorem.stableID]
        #expect(throws: StatementError.cycle(labels: ["Thm 1", "Lem 8", "Thm 1"])) { try graph.promote(cycle, in: problem) }
        #expect(throws: StatementError.noSuchSteps) { try graph.promote(draft(fixture.attemptA, 6, 9), in: problem) }
        let other = fixture.state.problems.createProblem(title: "Another problem")
        #expect(throws: StatementError.notInThisProblem) { try graph.promote(draft(fixture.attemptA, 1, 1), in: other) }
        #expect(problem.statements?.count == count)
        #expect(fixture.theorem.uses?.count == theoremUses)
        #expect(contextRevision == revision)
    }

    @Test("Invariant 13: an edge that would close a cycle is refused; a shortcut is fine")
    func edges() throws {
        let theorem = fixture.theorem.stableID, lemma1 = fixture.lemmas[0].stableID
        let lemma3 = fixture.lemmas[2].stableID, lemma5 = fixture.cappedLemma.stableID
        #expect(throws: StatementError.cycle(labels: ["Lem 1", "Lem 1"])) { try graph.addUse(lemma1, to: lemma1, in: problem) }
        #expect(throws: StatementError.cycle(labels: ["Lem 1", "Lem 3", "Lem 1"])) { try graph.addUse(lemma3, to: lemma1, in: problem) }
        #expect(throws: StatementError.cycle(labels: ["Lem 1", "Thm 1", "Lem 1"])) { try graph.addUse(theorem, to: lemma1, in: problem) }
        let revision = contextRevision
        try graph.addUse(lemma1, to: lemma5, in: problem)
        try graph.addUse(lemma1, to: lemma5, in: problem)
        #expect(fixture.cappedLemma.uses?.filter { $0.stableID == lemma1 }.count == 1)
        #expect(contextRevision == revision + 1, "adding an edge twice changes nothing the second time")
        graph.removeUse(lemma3, from: lemma5, in: problem)
        graph.removeUse(fixture.lemmas[3].stableID, from: lemma5, in: problem)
        #expect(graph.state(for: problem)[lemma5]?.derived.displayed == .formallyVerified,
                "with only Lem 1 left, nothing holds it down")
    }

    @Test("Labels stay unique; the theorem's text and a wording checked in Lean are fixed")
    func editing() throws {
        let lemma1 = fixture.lemmas[0], lemma6 = fixture.onRefutedClaim
        #expect(throws: StatementError.duplicateLabel("Lem 2")) {
            try graph.edit(lemma6.stableID, label: "Lem 2", statementLaTeX: lemma6.statementLaTeX, in: problem)
        }
        #expect(throws: StatementError.pinnedTextIsTheProblemStatement) {
            try graph.edit(fixture.theorem.stableID, label: "Thm 1", statementLaTeX: "Changed.", in: problem)
        }
        #expect(throws: StatementError.textLockedByLeanCheck) {
            try graph.edit(lemma1.stableID, label: "Lem 1", statementLaTeX: "Changed.", in: problem)
        }
        try graph.edit(lemma1.stableID, label: "Sylow counts", statementLaTeX: lemma1.statementLaTeX, in: problem)
        #expect(lemma1.label == "Sylow counts")
        try graph.edit(lemma6.stableID, label: "Lem 6", statementLaTeX: #"  If $n_q = p$, then $p \equiv 1 \pmod{q}$. "#, in: problem)
        #expect(lemma6.statementLaTeX == #"If $n_q = p$, then $p \equiv 1 \pmod{q}$."#)
    }

    @Test("Every problem has its theorem, whose text follows the problem statement")
    func theorem() throws {
        let problems = fixture.state.problems
        let created = problems.createProblem(title: "New", statementLaTeX: "Let $G$ be a group.")
        let theorem = try #require(problems.pinnedStatement(of: created))
        #expect(theorem.kind == .theorem)
        #expect(theorem.label == "Thm 1")
        #expect(theorem.author == .human(fixture.you.personID))
        try problems.update(created, title: "New", statementLaTeX: "Let $G$ be a $p$-group.")
        #expect(theorem.statementLaTeX == "Let $G$ be a $p$-group.")
        #expect(graph.state(for: created).pinned?.derived.displayed == .proposed)
        // A problem from before Milestone 4 has no theorem until launch gives it one, once.
        let legacy = Problem(title: "Old", statementLaTeX: "Old.")
        fixture.state.container.mainContext.insert(legacy)
        problems.ensurePinnedTheorems()
        problems.ensurePinnedTheorems()
        #expect(legacy.statements?.count == 1)
        #expect(problems.pinnedStatement(of: legacy)?.statementLaTeX == "Old.")
    }

    @Test("Deleting detaches the statement; what used it stays and may rise; the theorem stays")
    func deleting() throws {
        let window = WindowState()
        window.select(problem: problem)
        let lemma6 = fixture.onRefutedClaim.stableID
        window.reveal(statement: lemma6)
        #expect(throws: StatementError.pinnedTheoremCannotBeDeleted) {
            try window.delete(statement: fixture.theorem.stableID, in: problem, using: graph)
        }
        try window.delete(statement: lemma6, in: problem, using: graph)
        #expect(window.selectedNodeID == nil)
        let state = graph.state(for: problem)
        #expect(state[lemma6] == nil)
        #expect(state[fixture.belowRefuted.stableID]?.uses.isEmpty == true)
        #expect(state[fixture.belowRefuted.stableID]?.derived.displayed == .humanChecked)
        #expect(Set((fixture.attemptA.sortedSteps[2].statements ?? []).map(\.label)) == ["Thm 1", "Lem 3", "Lem 7"])
        fixture.state.saves.flush()
        #expect(fixture.state.saves.lastError == nil)
        #expect(try ModelContext(fixture.state.container).fetchCount(FetchDescriptor<Statement>()) == 9)
    }

    @Test("Renaming the theorem works whatever whitespace the problem statement has")
    func renameTheorem() throws {
        let problems = fixture.state.problems
        try problems.update(problem, title: problem.title, statementLaTeX: problem.statementLaTeX + "\n")
        let theorem = fixture.theorem
        #expect(theorem.statementLaTeX.hasSuffix("\n"))
        try graph.edit(theorem.stableID, label: "Main theorem", statementLaTeX: theorem.statementLaTeX, in: problem)
        #expect(theorem.label == "Main theorem")
        #expect(theorem.statementLaTeX == problem.statementLaTeX, "the text is left as the problem has it")
    }

    @Test("Invariant 12: once its wording is checked against Lean, the problem statement can no longer change")
    func lockedStatement() throws {
        let problems = fixture.state.problems
        let theorem = fixture.theorem
        theorem.recordLeanCheck(.trivial)
        let original = problem.statementLaTeX
        #expect(problems.statementIsLocked(problem))
        #expect(throws: StatementError.textLockedByLeanCheck) {
            try problems.update(problem, title: problem.title, statementLaTeX: "Every group is abelian.")
        }
        #expect(problem.statementLaTeX == original)
        #expect(theorem.statementLaTeX == original)
        try problems.update(problem, title: "Renamed", statementLaTeX: original)
        #expect(problem.title == "Renamed", "the title can still change")
        // A store where the two differ anyway keeps the checked wording at launch.
        problem.statementLaTeX = "Changed behind the editor's back."
        problems.ensurePinnedTheorems()
        #expect(theorem.statementLaTeX == original)
    }

    @Test("Deleting says what it does: what may rise, a refuted claim leaving the context, what goes with it")
    func deletionNotes() {
        let state = graph.state(for: problem)
        #expect(state.deletionNote(for: fixture.belowRefuted.stableID)
                == "Nothing uses it. The steps it came from stay in the thread.")
        #expect(state.deletionNote(for: fixture.onRefutedClaim.stableID)
                == "Lem 7 uses it and will no longer, so its status may rise. The steps it came from stay in the thread.")
        #expect(state.deletionNote(for: fixture.lemmas[0].stableID)
                == "Thm 1 and Lem 3 use it and will no longer, so their status may rise. Its Lean result, fidelity reviews and evidence are deleted with it. The steps it came from stay in the thread.")
        #expect(state.deletionNote(for: fixture.refutedClaim.stableID)
                == "Lem 6 uses it and will no longer, so its status may rise. Models will no longer be told it was refuted.")
    }

    @Test("A statement that is gone is said to be gone")
    func goneStatement() throws {
        let lemma7 = fixture.belowRefuted.stableID
        try graph.delete(lemma7, in: problem)
        #expect(throws: StatementError.noSuchStatement) { try graph.addUse(fixture.lemmas[0].stableID, to: lemma7, in: problem) }
        #expect(throws: StatementError.noSuchStatement) { try graph.delete(lemma7, in: problem) }
    }

    @Test("Deleting a problem whose statements use each other saves cleanly and leaves no statement")
    func deleteProblemWithEdges() throws {
        fixture.state.saves.flush()
        fixture.state.problems.delete(problem)
        fixture.state.saves.flush()
        #expect(fixture.state.saves.lastError == nil)
        #expect(try ModelContext(fixture.state.container).fetchCount(FetchDescriptor<Statement>()) == 0)
    }
}
