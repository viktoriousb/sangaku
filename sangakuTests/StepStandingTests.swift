import Foundation
import Testing
@testable import sangaku

/// Hand-built steps for the pure review rules. Times are minutes after a fixed instant.
private enum Build {
    static let me = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let colleague = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let slot = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static let people: Set<UUID> = [me, colleague]

    static func at(_ minute: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + minute * 60) }

    static func revision(_ minute: Double, establishes: String = "claim", author: Author? = .model(ModelSlotID(slot)),
                         text: String = "text") -> RevisionFact {
        RevisionFact(id: UUID(), createdAt: at(minute), author: author, textLaTeX: text, establishes: establishes)
    }

    static func review(_ verdict: ReviewVerdict, on revision: RevisionFact?, at minute: Double,
                       by reviewer: UUID? = me) -> ReviewFact {
        ReviewFact(id: UUID(), createdAt: at(minute), reviewerID: reviewer, verdict: verdict, revisionID: revision?.id)
    }

    static func step(_ index: Int, _ revisions: [RevisionFact], _ reviews: [ReviewFact] = [],
                     confidence: Confidence = .standard) -> StepFact {
        StepFact(id: UUID(), index: index, confidence: confidence, text: revisions.last?.textLaTeX ?? "",
                 establishes: revisions.last?.establishes ?? "", revisions: revisions, reviews: reviews)
    }

    static func standing(_ step: StepFact, verdicts: [VerdictFact] = []) -> StepStanding {
        StepStandings.derive(AttemptFact(id: UUID(), steps: [step], verdicts: verdicts), people: people)[0]
    }
}

@Suite("Step standing: people")
struct StepStandingHumanTests {
    @Test("Invariant 1: a ✓ from a model, from nobody or from an unknown reviewer counts for nothing")
    func onlyPeopleCheck() {
        let first = Build.revision(0)
        for reviewer in [Build.slot, UUID(), nil] as [UUID?] {
            let standing = Build.standing(Build.step(1, [first], [Build.review(.correct, on: first, at: 1, by: reviewer)]))
            #expect(standing.human == .unchecked && standing.uncounted.count == 1)
        }
        let person = Build.standing(Build.step(1, [first], [Build.review(.correct, on: first, at: 1)]))
        #expect(person.countsAsChecked)
    }

    @Test("Invariant 2: a ✓ applies to one revision; any new revision makes the step unchecked and keeps the old ✓")
    func editsResetReview() {
        let first = Build.revision(0)
        let check = Build.review(.correct, on: first, at: 1)
        for author in [Author.model(ModelSlotID(Build.slot)), .human(PersonID(Build.me))] {
            let second = Build.revision(2, author: author, text: "tidied")
            let standing = Build.standing(Build.step(1, [first, second], [check]))
            #expect(standing.human == .unchecked)
            #expect(standing.staleReviews == [check])
            #expect(standing.currentRevisionID == second.id)
        }
    }

    @Test("A step with no revision has nothing to check, so every review on it is stale")
    func noRevisionFailsClosed() {
        let standing = Build.standing(Build.step(1, [], [Build.review(.correct, on: nil, at: 1)]))
        #expect(standing.human == .unchecked && standing.staleReviews.count == 1)
    }

    @Test("Invariant 11: an open ✗ or ? blocks every ✓, including a later one from anyone")
    func objectionsBlock() {
        let first = Build.revision(0)
        for verdict in [ReviewVerdict.wrong, .unclear] {
            let objection = Build.review(verdict, on: first, at: 1, by: Build.colleague)
            let standing = Build.standing(Build.step(1, [first], [objection, Build.review(.correct, on: first, at: 2),
                                                                  Build.review(.correct, on: first, at: 3, by: Build.colleague)]))
            #expect(standing.human == .objected && !standing.countsAsChecked)
            #expect(standing.openObjections == [objection])
            #expect(standing.checks.count == 2, "the ✓s are kept and count once the objection closes")
        }
    }

    @Test("Invariant 11: a person's dismissal with a reason closes an objection; a model's or a blank one does not")
    func dismissals() {
        let first = Build.revision(0)
        func dismissed(by id: UUID?, reason: String?) -> StepStanding {
            var objection = Build.review(.wrong, on: first, at: 1)
            objection.dismissedByID = id
            objection.dismissalReason = reason
            objection.dismissedAt = Build.at(2)
            return Build.standing(Build.step(1, [first], [objection, Build.review(.correct, on: first, at: 3)]))
        }
        #expect(dismissed(by: Build.colleague, reason: "Fine: the parity argument covers it.").countsAsChecked)
        #expect(dismissed(by: Build.colleague, reason: "Fine").dismissedObjections.count == 1)
        #expect(dismissed(by: Build.slot, reason: "Fine").human == .objected, "a model cannot dismiss")
        #expect(dismissed(by: nil, reason: "Fine").human == .objected)
        #expect(dismissed(by: Build.colleague, reason: " \n ").human == .objected, "a reason is required")
        #expect(dismissed(by: Build.colleague, reason: nil).human == .objected)
    }

    @Test("Invariant 11: a new revision closes an objection, and so does its raiser's withdrawal, from a person only")
    func revisionClosesObjection() {
        let first = Build.revision(0)
        var objection = Build.review(.unclear, on: first, at: 1)
        objection.withdrawnAt = Build.at(2)
        let withdrawn = Build.standing(Build.step(1, [first], [objection, Build.review(.correct, on: first, at: 3)]))
        #expect(withdrawn.countsAsChecked && withdrawn.withdrawnObjections == [objection])
        for reviewer in [Build.slot, UUID(), nil] as [UUID?] {
            var untraced = objection
            untraced.reviewerID = reviewer
            #expect(Build.standing(Build.step(1, [first], [untraced])).human == .objected,
                    "a withdrawal that cannot be traced to a person leaves it open")
        }
        let second = Build.revision(3)
        let standing = Build.standing(Build.step(1, [first, second], [objection, Build.review(.correct, on: second, at: 4)]))
        #expect(standing.countsAsChecked && standing.staleReviews == [objection])
    }

    @Test("Invariant 11: an objection outlives its reviewer's record")
    func objectionsOutliveTheirReviewer() {
        let first = Build.revision(0)
        let gone = UUID()
        let standing = Build.standing(Build.step(1, [first], [Build.review(.wrong, on: first, at: 1, by: gone),
                                                              Build.review(.correct, on: first, at: 2)]))
        #expect(standing.human == .objected)
    }

    @Test("A withdrawn ✓ stops counting and stays in the record")
    func withdrawal() {
        let first = Build.revision(0)
        var check = Build.review(.correct, on: first, at: 1)
        check.withdrawnAt = Build.at(2)
        let standing = Build.standing(Build.step(1, [first], [check]))
        #expect(standing.human == .unchecked && standing.withdrawnChecks == [check])
        let again = Build.standing(Build.step(1, [first], [check, Build.review(.correct, on: first, at: 3)]))
        #expect(again.countsAsChecked)
    }

    @Test("Invariant 10: confidence never changes a standing")
    func confidenceIsIgnored() {
        let first = Build.revision(0)
        let reviews = [Build.review(.correct, on: first, at: 1)]
        let standings = Confidence.allCases.map { Build.standing(Build.step(1, [first], reviews, confidence: $0)) }
        #expect(Set(standings.map(\.human)) == [.checked])
        #expect(Set(standings.map(\.countsAsChecked)) == [true])
    }
}

@Suite("Step standing: the referee (rule 4)")
struct StepStandingModelTests {
    private let referee = UUID()

    private func verdict(_ outcome: RefereeOutcome, gaps: [Int] = [], at minute: Double = 10,
                         requested: Double? = 5) -> VerdictFact {
        VerdictFact(createdAt: Build.at(minute), outcome: outcome, gapStepIndices: gaps,
                    requestedAt: requested.map(Build.at), refereeID: referee)
    }

    @Test("Each case of rule 4 for one step")
    func cases() {
        let early = Build.step(1, [Build.revision(0)])
        let atRequest = Build.step(1, [Build.revision(5)])
        let late = Build.step(1, [Build.revision(0), Build.revision(6)])
        #expect(Build.standing(early).model == .noVerdict)
        #expect(Build.standing(early, verdicts: [verdict(.complete)]).model == .complete(referee: referee))
        #expect(Build.standing(atRequest, verdicts: [verdict(.complete)]).model.passes, "equal times are covered")
        #expect(Build.standing(late, verdicts: [verdict(.complete)]).model == .revisedSince(referee: referee))
        #expect(Build.standing(early, verdicts: [verdict(.complete, requested: nil)]).model == .unknownBasis(referee: referee))
        #expect(Build.standing(early, verdicts: [verdict(.gap, gaps: [1])]).model == .gapListed(referee: referee))
        #expect(Build.standing(early, verdicts: [verdict(.gap, gaps: [4])]).model == .attemptHasGap(referee: referee))
        #expect(Build.standing(Build.step(1, []), verdicts: [verdict(.complete)]).model == .revisedSince(referee: referee))
    }

    @Test("Tied verdicts cover only what the earliest request saw")
    func ties() {
        let step = Build.step(1, [Build.revision(0), Build.revision(6)])
        let both = [verdict(.complete, requested: 8), verdict(.complete, requested: 5)]
        #expect(!Build.standing(step, verdicts: both).model.passes)
        #expect(Build.standing(step, verdicts: [verdict(.complete, requested: 8)]).model.passes)
    }

    @Test("Invariant 1: a passing verdict never makes a step checked by a person")
    func modelNeverChecks() {
        let standing = Build.standing(Build.step(1, [Build.revision(0)]), verdicts: [verdict(.complete)])
        #expect(standing.model.passes && standing.human == .unchecked)
    }
}

@Suite("Step standing: re-check flags")
struct RecheckTests {
    /// Steps 1–4, all first written at minute 0; steps 2–4 checked at minute 1.
    private func attempt(revisingStep2 second: RevisionFact? = nil, extra: [Int: [ReviewFact]] = [:])
        -> (steps: [StepFact], standings: [StepStanding]) {
        let firsts = (1...4).map { Build.revision(0, establishes: "claim \($0)") }
        var steps = (1...4).map { index -> StepFact in
            let first = firsts[index - 1]
            let reviews = index == 1 ? [] : [Build.review(.correct, on: first, at: 1)]
            return Build.step(index, [first], reviews + (extra[index] ?? []))
        }
        if let second {
            steps[1].revisions.append(second)
            steps[1].reviews.append(Build.review(.correct, on: second, at: second.createdAt.timeIntervalSince(Build.at(0)) / 60 + 1))
        }
        return (steps, derive(steps))
    }

    @Test("Changing what step 2 establishes flags the later checked steps only")
    func flagsLaterCheckedSteps() {
        let change = Build.revision(5, establishes: "a stronger claim")
        let standings = attempt(revisingStep2: change).standings
        #expect(standings[0].recheck == nil, "an earlier, unchecked step")
        #expect(standings[1].recheck == nil, "the changed step itself")
        #expect(standings[2].recheck?.stepIndices == [2])
        #expect(standings[3].recheck?.causes == [Recheck.Cause(stepIndex: 2, revisionID: change.id, at: change.createdAt)])
        #expect(standings[2].countsAsChecked && standings[3].countsAsChecked, "a flag does not uncheck")
    }

    @Test("A text-only revision, whitespace changes and first revisions do not flag")
    func noFlag() {
        #expect(attempt(revisingStep2: Build.revision(5, establishes: "claim 2", text: "reworded")).standings
            .allSatisfy { $0.recheck == nil })
        #expect(attempt(revisingStep2: Build.revision(5, establishes: "  claim\n2 ")).standings.allSatisfy { $0.recheck == nil })
        #expect(attempt().standings.allSatisfy { $0.recheck == nil })
    }

    @Test("A fresh ✓ after the change clears the flag; the latest of several ✓s is the one that counts")
    func freshCheckClears() {
        var steps = attempt(revisingStep2: Build.revision(5, establishes: "a stronger claim")).steps
        steps[2].reviews.append(Build.review(.correct, on: steps[2].revisions[0], at: 6, by: Build.colleague))
        let standings = derive(steps)
        #expect(standings[2].recheck == nil)
        #expect(standings[3].recheck != nil)
    }

    @Test("Equal times flag, in doubt")
    func equalTimesFlag() {
        let standings = attempt(revisingStep2: Build.revision(1, establishes: "changed")).standings
        #expect(standings[2].recheck != nil)
    }

    @Test("Unchecked, objected and withdrawn-only steps are not flagged")
    func onlyCheckedStepsAreFlagged() {
        var steps = attempt(revisingStep2: Build.revision(5, establishes: "a stronger claim")).steps
        var withdrawn = Build.review(.correct, on: steps[2].revisions[0], at: 2)
        withdrawn.withdrawnAt = Build.at(3)
        steps[2].reviews = [withdrawn]
        steps[3].reviews.append(Build.review(.unclear, on: steps[3].revisions[0], at: 2))
        let standings = derive(steps)
        #expect(standings[2].recheck == nil && standings[3].recheck == nil)
        #expect(standings[2].changedSinceCheck == nil, "a withdrawn ✓ is no check")
        #expect(standings[3].changedSinceCheck?.stepIndices == [2],
                "an objected step keeps the cause, for when its ✓ counts again")
    }

    private func derive(_ steps: [StepFact]) -> [StepStanding] {
        StepStandings.derive(AttemptFact(id: UUID(), steps: steps), people: Build.people)
    }
}

@Suite("Review progress (invariant 8)")
struct ReviewProgressTests {
    private func standing(_ human: HumanStanding, flagged: Bool = false) -> StepStanding {
        let first = Build.revision(0)
        var reviews: [ReviewFact] = []
        if human != .unchecked { reviews.append(Build.review(.correct, on: first, at: 1)) }
        if human == .objected { reviews.append(Build.review(.unclear, on: first, at: 2)) }
        var result = Build.standing(Build.step(1, [first], reviews))
        if flagged { result.changedSinceCheck = Recheck(causes: [.init(stepIndex: 0, revisionID: UUID(), at: Build.at(3))]) }
        return result
    }

    @Test("Four of six, said exactly; never complete with an objection or a missing check")
    func wording() {
        let progress = ReviewProgress([standing(.checked), standing(.checked), standing(.checked), standing(.checked),
                                       standing(.objected), standing(.unchecked)])
        #expect(progress.headline == "4 of 6 steps checked by a person")
        #expect(progress.notes == ["1 with an open objection"])
        #expect(!progress.isComplete)
        #expect(ReviewProgress([standing(.checked)]).headline == "1 of 1 step checked by a person")
        #expect(ReviewProgress([standing(.checked)]).isComplete)
        #expect(ReviewProgress([]).headline == "No steps" && !ReviewProgress([]).isComplete)
    }

    @Test("A flagged step still counts as checked, and the note says so")
    func flagged() {
        let progress = ReviewProgress([standing(.checked, flagged: true), standing(.checked)])
        #expect(progress.isComplete && progress.notes == ["1 flagged for re-check"])
        #expect(progress.headline == "2 of 2 steps checked by a person")
    }
}

@Suite("Provenance (invariant 7)")
struct StepProvenanceTests {
    private let a = Author.model(ModelSlotID(Build.slot))
    private let you = Author.human(PersonID(Build.me))

    @Test("Versions read the revision history in order, with who changed what")
    func versions() {
        let one = Build.revision(0, author: a)
        let two = Build.revision(5, author: you, text: "tidied")
        let three = Build.revision(9, establishes: "new", author: a, text: "tidied")
        let provenance = StepProvenance(revisions: [three, one, two])
        #expect(provenance.versions.map(\.author) == [a, you, a])
        #expect(provenance.versions.map(\.number) == [1, 2, 3])
        #expect(provenance.versions.map(\.changedText) == [false, true, false])
        #expect(provenance.versions.map(\.changedEstablishes) == [false, false, true])
        #expect(provenance.versions.map(\.isCurrent) == [false, false, true])
        #expect(provenance.isRevised && provenance.original?.id == one.id && provenance.current?.id == three.id)
        #expect(provenance.revisingPerson == nil, "the current text is the model's")
        #expect(StepProvenance(revisions: [one, two]).revisingPerson == you)
        #expect(StepProvenance(revisions: [one]).revisingPerson == nil)
        #expect(StepProvenance(revisions: []).current == nil)
    }
}

@Suite("Review state for an attempt")
struct AttemptReviewStateTests {
    @Test("Rotors: unchecked steps include objected ones; delicate steps follow confidence only (invariant 10)")
    func rotors() {
        let first = Build.revision(0)
        let steps = [
            Build.step(1, [first], [Build.review(.correct, on: first, at: 1)], confidence: .delicate),
            Build.step(2, [first], [Build.review(.unclear, on: first, at: 1)]),
            Build.step(3, [first], confidence: .delicate),
        ]
        let state = AttemptReviewState(AttemptFact(id: UUID(), steps: steps.reversed()), people: Build.people)
        #expect(state.steps.map(\.index) == [1, 2, 3])
        #expect(state.uncheckedStepIDs == [steps[1].id, steps[2].id])
        #expect(state.delicateStepIDs == [steps[0].id, steps[2].id])
        #expect(state.progress.headline == "1 of 3 steps checked by a person")
    }

    @Test("History lists versions, reviews, dismissals and comments, newest first")
    func history() {
        let one = Build.revision(0)
        var objection = Build.review(.unclear, on: one, at: 2)
        objection.dismissedByID = Build.me
        objection.dismissalReason = "Answered in the comment."
        objection.dismissedAt = Build.at(4)
        let comment = CommentFact(id: UUID(), createdAt: Build.at(3), author: .human(PersonID(Build.me)),
                                  body: "Why (2, 3)?", revisionID: one.id)
        var step = Build.step(1, [one, Build.revision(5)], [objection])
        step.comments = [comment]
        let review = AttemptReviewState(AttemptFact(id: UUID(), steps: [step]), people: Build.people).steps[0]
        #expect(review.history.map(\.id) == ["version-\(step.revisions[1].id)", "dismissal-\(objection.id)",
                                             "comment-\(comment.id)", "review-\(objection.id)", "version-\(one.id)"])
        #expect(review.versionLabel(of: one.id) == "version 1")
        #expect(review.versionLabel(of: step.revisions[1].id) == nil, "the current version needs no label")
    }
}

/// SplitMix64: a small seeded generator, so the property test is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("One rule for every reader (invariant 3)")
struct SharedRuleTests {
    /// The spec's rule 3, written out naively from CLAUDE.md, as the oracle.
    private func specSaysChecked(_ step: StepFact) -> Bool {
        guard let current = step.revisions.max(by: RevisionFact.precedes) else { return false }
        let onCurrent = step.reviews.filter { $0.revisionID == current.id }
        let personCheck = onCurrent.contains {
            $0.verdict == .correct && $0.withdrawnAt == nil && $0.reviewerID.map(Build.people.contains) == true
        }
        let open = onCurrent.contains {
            $0.verdict != .correct && !($0.dismissedByID.map(Build.people.contains) == true
                && !($0.dismissalReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                && !($0.withdrawnAt != nil && $0.reviewerID.map(Build.people.contains) == true)
        }
        return personCheck && !open
    }

    @Test("200 random attempts: status, progress and the spec's rule agree on every step")
    func randomAttempts() {
        var random = SeededGenerator(state: 5)
        let reviewers: [UUID?] = [Build.me, Build.colleague, Build.slot, UUID(), nil]
        for _ in 0..<200 {
            let steps = (1...Int.random(in: 1...5, using: &random)).map { index -> StepFact in
                let revisions = (0..<Int.random(in: 0...3, using: &random)).map {
                    Build.revision(Double($0 * 10), establishes: Bool.random(using: &random) ? "x" : "y")
                }
                let reviews = (0..<Int.random(in: 0...4, using: &random)).map { _ -> ReviewFact in
                    let on = Bool.random(using: &random) ? revisions.last : revisions.randomElement(using: &random)
                    var review = Build.review(ReviewVerdict.allCases.randomElement(using: &random)!, on: on,
                                              at: Double.random(in: 0...40, using: &random),
                                              by: reviewers.randomElement(using: &random)!)
                    if Bool.random(using: &random) { review.dismissedByID = reviewers.randomElement(using: &random)! }
                    if Bool.random(using: &random) { review.dismissalReason = ["", " ", "Fine."].randomElement(using: &random) }
                    if Int.random(in: 0..<4, using: &random) == 0 { review.withdrawnAt = Build.at(41) }
                    return review
                }
                return Build.step(index, revisions, reviews)
            }
            let standings = StepStandings.derive(AttemptFact(id: UUID(), steps: steps), people: Build.people)
            for (step, standing) in zip(steps, standings) {
                #expect(standing.countsAsChecked == specSaysChecked(step))
                let source = StatusInputs.SourceStep(standing)
                #expect((source.checkedOnCurrentRevision && !source.hasOpenObjection) == standing.countsAsChecked)
            }
            let own = StatusRules.ownStatus(StatusInputs(sourceSteps: standings.map(StatusInputs.SourceStep.init)))
            #expect(ReviewProgress(standings).isComplete == (own == .humanChecked))
        }
    }
}
