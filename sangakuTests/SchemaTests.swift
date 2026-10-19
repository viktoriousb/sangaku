import Foundation
import SwiftData
import Testing
@testable import sangaku

@Suite("Schema v1")
struct SchemaTests {
    @Test("CloudKit rules: defaults or optionals, optional relationships with inverses, nothing unique")
    func cloudKitRules() {
        let schema = Schema(versionedSchema: SangakuSchemaV1.self)
        #expect(schema.entities.count == SangakuSchemaV1.models.count)
        for entity in schema.entities {
            for attribute in entity.attributes {
                #expect(!attribute.isUnique, "\(entity.name).\(attribute.name) is unique")
                #expect(attribute.isOptional || attribute.defaultValue != nil,
                        "\(entity.name).\(attribute.name) has neither a default nor an optional type")
            }
            for relationship in entity.relationships {
                #expect(relationship.isOptional, "\(entity.name).\(relationship.name) is not optional")
                #expect(relationship.inverseName != nil, "\(entity.name).\(relationship.name) has no inverse")
                #expect(relationship.deleteRule != .deny, "\(entity.name).\(relationship.name) uses .deny")
            }
        }
    }

    @Test("Every model carries a stable ID and a creation date from version 1")
    func stableIdentity() {
        let schema = Schema(versionedSchema: SangakuSchemaV1.self)
        for entity in schema.entities {
            let names = Set(entity.attributes.map(\.name))
            #expect(names.contains("stableID"), "\(entity.name) has no stableID")
            #expect(names.contains("createdAt"), "\(entity.name) has no createdAt")
        }
    }

    @Test("Deleting a problem deletes what it owns")
    func cascadeFromProblem() throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let context = container.mainContext
        let problem = Problem(title: "P", statementLaTeX: "x")
        context.insert(problem)
        let entry = NotationEntry(symbolLaTeX: "G", meaning: "a group")
        let branch = Branch(name: "Main")
        let message = Message(bodyLaTeX: "prove it")
        let statement = Statement(kind: .theorem, label: "Thm 1", statementLaTeX: "x")
        let lean = LeanResult(source: "theorem t : True := trivial")
        let slot = ModelSlot(letter: "A", role: .prover)
        problem.notation = [entry]
        problem.branches = [branch]
        problem.statements = [statement]
        problem.modelSlots = [slot]
        branch.messages = [message]
        statement.leanResult = lean
        try context.save()

        context.delete(problem)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<NotationEntry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Branch>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Statement>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<LeanResult>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ModelSlot>()) == 0)
    }

    @Test("Deleting a person keeps the reviews they wrote, with their ID (provenance survives)")
    func reviewsOutlivePeople() throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let context = container.mainContext
        let person = Person(name: "MK", initials: "MK")
        let step = Step(index: 1, textLaTeX: "x")
        let review = Review(reviewer: person.personID, verdict: .correct)
        context.insert(person)
        context.insert(step)
        step.reviews = [review]
        try context.save()

        let reviewerID = person.stableID
        context.delete(person)
        try context.save()

        let reviews = try context.fetch(FetchDescriptor<Review>())
        #expect(reviews.count == 1)
        #expect(reviews.first?.reviewerID == reviewerID)
    }

    @Test("A step's comments go with it, outlive their author, and carry no verdict; new review fields start empty")
    func stepComments() throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let context = container.mainContext
        let person = Person(name: "MK", initials: "MK")
        let step = Step(index: 1, textLaTeX: "x")
        let comment = StepComment(author: .human(person.personID), body: "Why?", revisionID: UUID())
        context.insert(person)
        context.insert(step)
        step.comments = [comment]
        try context.save()

        context.delete(person)
        try context.save()
        let kept = try context.fetch(FetchDescriptor<StepComment>())
        #expect(kept.count == 1 && kept.first?.author == .human(person.personID))

        context.delete(step)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<StepComment>()) == 0)
        #expect(Review().withdrawnAt == nil)
        #expect(RefereeVerdict().requestedAt == nil, "an old verdict covers no step (rule 4)")
    }

    @Test("Deleting a statement leaves the steps it was built from")
    func nullifyKeepsSteps() throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let context = container.mainContext
        let step = Step(index: 1, textLaTeX: "x")
        let statement = Statement(kind: .lemma, label: "Lem 1")
        context.insert(step)
        context.insert(statement)
        statement.sourceSteps = [step]
        try context.save()

        context.delete(statement)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Step>()) == 1)
    }

    @Test("Unknown stored values fall back to the least-trusting case")
    func leastTrustingFallbacks() {
        let review = Review(verdict: .correct)
        review.verdictRaw = "certainly-correct"
        #expect(review.verdict == .unclear)

        let verdict = RefereeVerdict()
        #expect(verdict.outcome == .gap)

        let citation = Citation(rawText: "Kessler & Varga (2019)")
        #expect(citation.status == .unverified)

        let fidelity = FidelityReview()
        #expect(fidelity.verdict == .differs)

        #expect(ReviewVerdict(stored: nil) == .unclear)
        #expect(Confidence(stored: "whatever") == .guess)
    }

    @Test("Author round-trips through its two columns; missing data gives nil, not a guess")
    func authorRoundTrip() {
        let slot = ModelSlotID(UUID())
        let person = PersonID(UUID())
        let message = Message(author: .model(slot), bodyLaTeX: "x")
        #expect(message.author == .model(slot))
        message.author = .human(person)
        #expect(message.authorKindRaw == "human")
        #expect(message.author == .human(person))
        message.authorKindRaw = "alien"
        #expect(message.author == nil)
        message.author = nil
        #expect(message.authorID == nil)
    }

    @Test("A store written to disk reopens with its data")
    func reopenFromDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sangaku-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "test.store")

        do {
            let container = try ModelContainerFactory.make(.disk(url))
            let problem = Problem(title: "Groups of order 36")
            container.mainContext.insert(problem)
            try container.mainContext.save()
        }
        let reopened = try ModelContainerFactory.make(.disk(url))
        let titles = try reopened.mainContext.fetch(FetchDescriptor<Problem>()).map(\.title)
        #expect(titles == ["Groups of order 36"])
    }
}
