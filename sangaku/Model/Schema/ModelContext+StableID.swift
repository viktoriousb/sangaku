import Foundation
import SwiftData

/// Finding an entity by its stable ID: the key links, provenance and plain-file copies use. One overload per entity,
/// because a predicate over a generic entity's key path is not `Sendable`.
extension ModelContext {
    func first(_ type: Problem.Type, stableID id: UUID) -> Problem? { first(#Predicate<Problem> { $0.stableID == id }) }
    func first(_ type: Branch.Type, stableID id: UUID) -> Branch? { first(#Predicate<Branch> { $0.stableID == id }) }
    func first(_ type: Message.Type, stableID id: UUID) -> Message? { first(#Predicate<Message> { $0.stableID == id }) }
    func first(_ type: RequestRecord.Type, stableID id: UUID) -> RequestRecord? {
        first(#Predicate<RequestRecord> { $0.stableID == id })
    }
    func first(_ type: FanOut.Type, stableID id: UUID) -> FanOut? { first(#Predicate<FanOut> { $0.stableID == id }) }
    func first(_ type: ProofAttempt.Type, stableID id: UUID) -> ProofAttempt? {
        first(#Predicate<ProofAttempt> { $0.stableID == id })
    }
    func first(_ type: Step.Type, stableID id: UUID) -> Step? { first(#Predicate<Step> { $0.stableID == id }) }
    func first(_ type: Review.Type, stableID id: UUID) -> Review? { first(#Predicate<Review> { $0.stableID == id }) }
    func first(_ type: Statement.Type, stableID id: UUID) -> Statement? {
        first(#Predicate<Statement> { $0.stableID == id })
    }
    func first(_ type: LeanDraft.Type, stableID id: UUID) -> LeanDraft? {
        first(#Predicate<LeanDraft> { $0.stableID == id })
    }
    func first(_ type: ComputeCell.Type, stableID id: UUID) -> ComputeCell? {
        first(#Predicate<ComputeCell> { $0.stableID == id })
    }
    func first(_ type: Evidence.Type, stableID id: UUID) -> Evidence? { first(#Predicate<Evidence> { $0.stableID == id }) }
    func first(_ type: Citation.Type, stableID id: UUID) -> Citation? { first(#Predicate<Citation> { $0.stableID == id }) }

    private func first<Entity: PersistentModel>(_ predicate: Predicate<Entity>) -> Entity? {
        var descriptor = FetchDescriptor<Entity>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }
}
