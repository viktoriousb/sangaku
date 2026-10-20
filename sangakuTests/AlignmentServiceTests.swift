import Foundation
import Observation
import SwiftData
import Testing
@testable import sangaku

/// Counts `markDirty` calls: each one starts a save task, which calls the injected sleep.
private final class Saves {
    var count = 0
}

/// Set from an observation callback, which runs synchronously on the main thread during the change.
nonisolated private final class Fired: @unchecked Sendable {
    var value = false
}

@Suite("Alignment service")
struct AlignmentServiceTests {
    private let fixture = PreviewFixtures.make()
    private let saves = Saves()
    private let service: AlignmentService
    private let frozen = Date(timeIntervalSinceReferenceDate: 900_000_000)

    init() {
        let counter = saves
        let scheduler = SaveScheduler(context: fixture.state.container.mainContext, sleep: { _ in
            counter.count += 1
            throw CancellationError()
        })
        let frozen = frozen
        service = AlignmentService(context: fixture.state.container.mainContext, saves: scheduler,
                                   problems: fixture.state.problems, now: { frozen })
    }

    private var state: ComparisonState { service.comparison(of: fixture.attemptA, fixture.attemptB)! }
    private var pair: ComparedPair { state.pair }
    private var contextRevision: Int { fixture.state.problems.contextRevisions[fixture.problem.stableID, default: 0] }

    private func saveCount() async -> Int {
        for _ in 0..<10 { await Task.yield() }
        defer { saves.count = 0 }
        return saves.count
    }

    /// The row holding side 1's step `n`.
    private func row(_ index: Int) -> CompareRow { state.rows.first { $0.a?.index == index }! }

    @Test("Re-pairing: a person's pair and separation, kept apart from the model's rows, one save each")
    func repair() async throws {
        _ = await saveCount()
        let revision = contextRevision
        let first = row(1), second = row(2)
        let crossed = RowKey(a: first.a?.id, b: second.b?.id)
        try service.pair(crossed, in: pair)
        #expect(state[row: crossed]?.state == .notCompared, "re-paired by hand, not yet judged")
        #expect(await saveCount() == 1)
        #expect(contextRevision == revision, "comparisons are never sent to models")
        try service.unpair(crossed, in: pair)
        #expect(state[row: crossed] == nil)
        #expect(fixture.alignment.corrections.map(\.action) == [.pair, .unpair] && fixture.alignment.correctedByUser)
        #expect(fixture.alignment.corrections.allSatisfy { $0.personID == fixture.you.stableID && $0.at == frozen })

        // A new model alignment replaces only the model's rows: the person's decisions stay.
        fixture.alignment.rows = fixture.alignment.rows?.map { var row = $0; row.verdict = "equivalent"; return row }
        #expect(state[row: crossed] == nil)
        #expect(state.rows.first { $0.a?.id == first.a?.id }?.judgedBy == .person)
    }

    @Test("Judging is on the revisions the person read; a revised step refuses it")
    func judge() async throws {
        let diverging = try #require(ThreadAgreement.firstDivergence(state.rows))
        let seen = RowKey(a: diverging.a?.revisionID, b: diverging.b?.revisionID)
        try service.judge(.equivalent, diverging.id, seen: seen, in: pair)
        #expect(state[row: diverging.id]?.state == .equivalent && state[row: diverging.id]?.judgedBy == .person)
        try service.clearJudgement(diverging.id, in: pair)
        #expect(state[row: diverging.id]?.state == .diverge && state[row: diverging.id]?.judgedBy == .model)

        let step = fixture.attemptB.sortedSteps[4]
        try fixture.state.reviews.revise(step.stableID, from: step.latestRevision!.stableID, text: "Repaired.",
                                         establishes: step.establishes)
        let count = fixture.alignment.corrections.count
        _ = await saveCount()
        #expect(throws: CompareError.staleRevision) { try service.judge(.equivalent, diverging.id, seen: seen, in: pair) }
        #expect(fixture.alignment.corrections.count == count)
        #expect(await saveCount() == 0)
    }

    @Test("Refusals change nothing")
    func refusals() async throws {
        let before = fixture.alignment.correctionsJSON
        _ = await saveCount()
        let one = row(1)
        #expect(throws: CompareError.notAPair) {
            try service.pair(one.id, in: ComparedPair(first: fixture.attemptA.stableID, second: fixture.attemptA.stableID))
        }
        #expect(throws: CompareError.noSuchAttempt) {
            try service.pair(one.id, in: ComparedPair(first: UUID(), second: fixture.attemptB.stableID))
        }
        #expect(throws: CompareError.stepNotInAttempt) { try service.pair(RowKey(a: UUID(), b: one.b?.id), in: pair) }
        #expect(throws: CompareError.notPaired) { try service.unpair(RowKey(a: one.a?.id, b: row(2).b?.id), in: pair) }
        try service.pair(one.id, in: pair)                  // already paired: nothing to do
        try service.clearJudgement(one.id, in: pair)        // nothing of the person's to clear
        fixture.alignment.correctionsJSON = Data("[{".utf8)
        #expect(throws: CompareError.correctionsUnreadable) { try service.unpair(one.id, in: pair) }
        #expect(fixture.alignment.correctionsJSON == Data("[{".utf8))
        fixture.alignment.correctionsJSON = before
        #expect(await saveCount() == 0)
    }

    @Test("Steps given the other way round are stored side 1 first")
    func orientation() throws {
        let one = row(1)
        try service.unpair(RowKey(a: one.b?.id, b: one.a?.id), in: ComparedPair(first: pair.second, second: pair.first))
        #expect(fixture.alignment.corrections.first?.stepAID == one.a?.id)
    }

    @Test("A first correction creates the comparison, its sides fixed by the attempts' IDs")
    func creates() throws {
        fixture.problem.alignments = []
        fixture.state.container.mainContext.delete(fixture.alignment)
        let one = row(1)
        try service.unpair(one.id, in: pair)
        let created = try #require(fixture.problem.alignment(between: pair.first, and: pair.second))
        #expect(created.attemptAID == ComparedPair.oriented(pair.second, pair.first).first)
        #expect(created.rows == nil && created.corrections.count == 1)
    }

    @Test("Invariant 9 and 1: the blind verdict is recorded once, with who and when, and changes no status")
    func holds() async throws {
        let graph = fixture.state.graph.state(for: fixture.problem)
        _ = await saveCount()
        try service.recordHolds(.first, in: pair)
        #expect(fixture.alignment.holds == .first)
        #expect(fixture.alignment.holdsByID == fixture.you.stableID && fixture.alignment.holdsAt == frozen)
        #expect(await saveCount() == 1)
        #expect(throws: CompareError.verdictAlreadyRecorded) { try service.recordHolds(.second, in: pair) }
        #expect(fixture.alignment.holds == .first)
        #expect(fixture.state.graph.state(for: fixture.problem) == graph)
        #expect(!CompareBlind.hides(windowBlind: true, verdictRecorded: fixture.alignment.holds != nil))
    }

    @Test("A stored verdict this version cannot read counts as recorded and is never written over")
    func unreadableVerdict() throws {
        fixture.alignment.holdsRaw = "maybe"
        #expect(throws: CompareError.verdictAlreadyRecorded) { try service.recordHolds(.first, in: pair) }
        #expect(fixture.alignment.holdsRaw == "maybe")
    }

    @Test("A step with no recorded revision cannot be judged: nothing would say which text was judged")
    func noRevision() throws {
        let one = row(1)
        let step = try #require(fixture.attemptB.sortedSteps.first { $0.stableID == one.b?.id || $0.stableID == one.a?.id })
        for revision in step.revisions ?? [] { fixture.state.container.mainContext.delete(revision) }
        step.revisions = []
        let bare = row(1)
        #expect(throws: CompareError.noRevision) {
            try service.judge(.equivalent, bare.id, seen: RowKey(a: bare.a?.revisionID, b: bare.b?.revisionID), in: pair)
        }
    }

    @Test("Separating a judged pair and pairing it again starts it unjudged")
    func separationClears() throws {
        let one = row(1)
        try service.judge(.diverge, one.id, seen: RowKey(a: one.a?.revisionID, b: one.b?.revisionID), in: pair)
        #expect(state[row: one.id]?.judgedBy == .person)
        try service.unpair(one.id, in: pair)
        try service.pair(one.id, in: pair)
        #expect(state[row: one.id]?.judgedBy == .model, "back to the model's reading, not the person's")
    }

    @Test("Invariant 1: pairing, separating and judging change no review, step standing or status")
    func correctionsGrantNothing() throws {
        let graph = fixture.state.graph.state(for: fixture.problem)
        let context = fixture.state.container.mainContext
        let reviews = try context.fetchCount(FetchDescriptor<Review>())
        let people = fixture.state.problems.personIDs()
        func standings() -> [UUID: StepStanding] {
            StepStandings.standings(of: fixture.attemptA.sortedSteps + fixture.attemptB.sortedSteps, people: people)
        }
        let before = standings()
        let one = row(1), two = row(2)
        try service.judge(.equivalent, two.id, seen: RowKey(a: two.a?.revisionID, b: two.b?.revisionID), in: pair)
        try service.clearJudgement(two.id, in: pair)
        try service.judge(.diverge, two.id, seen: RowKey(a: two.a?.revisionID, b: two.b?.revisionID), in: pair)
        try service.unpair(one.id, in: pair)
        try service.pair(RowKey(a: one.a?.id, b: two.b?.id), in: pair)
        #expect(fixture.state.graph.state(for: fixture.problem) == graph)
        #expect(try context.fetchCount(FetchDescriptor<Review>()) == reviews)
        #expect(standings() == before)
    }

    @Test("Views reading the comparison are told about corrections and the blind verdict")
    func observation() throws {
        func invalidates(_ change: () throws -> Void) rethrows -> Bool {
            let fired = Fired()
            let people = fixture.state.problems.personIDs()
            withObservationTracking {
                _ = ComparisonState.read(fixture.attemptA, fixture.attemptB, in: fixture.problem, people: people)
                _ = fixture.problem.alignment(between: fixture.attemptA.stableID, and: fixture.attemptB.stableID)?.holds
            } onChange: {
                fired.value = true
            }
            try change()
            return fired.value
        }
        let one = row(1)
        #expect(try invalidates { try service.unpair(one.id, in: pair) })
        #expect(try invalidates { try service.recordHolds(.both, in: pair) })
    }
}
