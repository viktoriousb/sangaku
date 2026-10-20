import Foundation
import SwiftData
import Testing
@testable import sangaku

@Suite("Compare: the stored comparison")
struct CompareStoreTests {
    private let fixture = PreviewFixtures.make()
    private var people: Set<UUID> { fixture.state.problems.personIDs() }

    private func state() -> ComparisonState {
        ComparisonState.read(fixture.attemptA, fixture.attemptB, in: fixture.problem, people: people)
    }

    /// Row `n` of the table as A's step `n` sees it.
    private func rowOfA(_ index: Int, in state: ComparisonState) -> CompareRow? {
        state.rows.first { ($0.a?.index == index && state.first.id == fixture.attemptA.stableID)
            || ($0.b?.index == index && state.second.id == fixture.attemptA.stableID) }
    }

    @Test("The example: four rows equivalent, one diverging with its key phrases, step 6 only in A")
    func example() throws {
        let state = state()
        #expect(state.first.id == fixture.alignment.attemptAID)
        #expect(Set([state.first.id, state.second.id]) == [fixture.attemptA.stableID, fixture.attemptB.stableID])
        #expect(state.summary.equivalent == 4 && state.summary.diverge == 1 && state.summary.onlyOne == 1)
        #expect(state.rows.allSatisfy { $0.judgedBy == .model })
        let diverging = try #require(ThreadAgreement.firstDivergence(state.rows))
        #expect(diverging.markA != nil && diverging.markB != nil, "both phrases are in the current text")
        #expect(diverging.note?.contains("Attempt") == true && diverging.note?.contains("Model") == false)
        // Either way round, the same pair of attempts reads the same stored comparison.
        let reversed = ComparisonState.read(fixture.attemptB, fixture.attemptA, in: fixture.problem, people: people)
        #expect(reversed.rows == state.rows)
    }

    @Test("Invariant 2: a person's revision of a step makes its row out of date; nothing else changes")
    func revisionMakesStale() throws {
        let step = fixture.attemptA.sortedSteps[1]
        try fixture.state.reviews.revise(step.stableID, from: step.latestRevision!.stableID, text: "Reworded.",
                                         establishes: step.establishes)
        let state = state()
        #expect(rowOfA(2, in: state)?.state == .stale)
        #expect(state.summary.equivalent == 3 && state.summary.stale == 1)
        #expect(ThreadAgreement.collapsedRuns(state.rows, side: state.second.id == fixture.attemptB.stableID ? .second : .first)
                == [3...4])
    }

    @Test("Invariant 1: a comparison is never a check; statuses and step standings ignore it")
    func neverTrust() {
        let before = fixture.state.graph.state(for: fixture.problem)
        let standings = fixture.state.reviews.state(of: fixture.attemptB)
        fixture.problem.alignments = []
        fixture.state.container.mainContext.delete(fixture.alignment)
        #expect(fixture.state.graph.state(for: fixture.problem) == before)
        #expect(fixture.state.reviews.state(of: fixture.attemptB) == standings)
    }

    @Test("Unreadable stored layers: labels only, and the comparison says so")
    func unreadable() {
        fixture.alignment.rowsJSON = Data("not json".utf8)
        fixture.alignment.correctionsJSON = Data("[{".utf8)
        #expect(!fixture.alignment.rowsAreReadable && !fixture.alignment.correctionsAreReadable)
        let state = state()
        #expect(state.modelRowsUnreadable && state.correctionsUnreadable)
        #expect(state.rows.allSatisfy { $0.judgedBy == .none })
        #expect(state.summary.equivalent == 0)
    }

    @Test("A comparison and its requests go with the problem; deleting a request leaves the comparison")
    func cascade() throws {
        let context = fixture.state.container.mainContext
        let record = RequestRecord()
        context.insert(record)
        record.alignment = fixture.alignment
        try context.save()
        context.delete(record)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Alignment>()) == 1)
        let another = RequestRecord()
        context.insert(another)
        another.alignment = fixture.alignment
        try context.save()
        context.delete(fixture.problem)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Alignment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RequestRecord>(predicate: #Predicate { $0.alignment != nil })) == 0)
    }

    @Test("A blind verdict that is not a known value reads as none (and still counts as recorded: AlignmentServiceTests)")
    func holds() {
        #expect(fixture.alignment.holds == nil)
        fixture.alignment.holdsRaw = "second"
        #expect(fixture.alignment.holds == .second)
        fixture.alignment.holdsRaw = "maybe"
        #expect(fixture.alignment.holds == nil)
    }
}
