import Foundation
import SwiftData

/// Schema version 1. The models are declared in `Model/Entities` as extensions of this namespace, and the
/// rest of the app uses them through the typealiases at the bottom of this file.
///
/// CloudKit-compatible from day one, though v1 does not sync: every attribute has a default or is optional,
/// every relationship is optional with an inverse and an explicit delete rule, and nothing is `.unique`
/// (uniqueness is enforced in code). Every model carries a `stableID` from its first version: adding a
/// UUID-defaulted property later would give every existing row the same value.
///
/// Until real research data exists, V1 may still be edited and the store is scratch, though deleting it is
/// still asked first. After first real use it is frozen and changes go into V2 with a migration stage. See
/// `docs/DECISIONS.md`, "The data store is scratch until real use".
nonisolated enum SangakuSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Problem.self, Person.self, ModelSlot.self, NotationEntry.self,
            Branch.self, Message.self, RequestRecord.self, FanOut.self, RefereeVerdict.self,
            ProofAttempt.self, Step.self, StepRevision.self, Review.self, StepComment.self, Citation.self,
            Statement.self, FidelityReview.self, Evidence.self, LeanResult.self,
            Alignment.self, LeanDraft.self, ComputeCell.self,
        ]
    }
}

nonisolated enum SangakuMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SangakuSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

typealias Problem = SangakuSchemaV1.Problem
typealias Person = SangakuSchemaV1.Person
typealias ModelSlot = SangakuSchemaV1.ModelSlot
typealias NotationEntry = SangakuSchemaV1.NotationEntry
typealias Branch = SangakuSchemaV1.Branch
typealias Message = SangakuSchemaV1.Message
typealias RequestRecord = SangakuSchemaV1.RequestRecord
typealias FanOut = SangakuSchemaV1.FanOut
typealias RefereeVerdict = SangakuSchemaV1.RefereeVerdict
typealias ProofAttempt = SangakuSchemaV1.ProofAttempt
typealias Step = SangakuSchemaV1.Step
typealias StepRevision = SangakuSchemaV1.StepRevision
typealias Review = SangakuSchemaV1.Review
typealias StepComment = SangakuSchemaV1.StepComment
typealias Citation = SangakuSchemaV1.Citation
typealias Statement = SangakuSchemaV1.Statement
typealias FidelityReview = SangakuSchemaV1.FidelityReview
typealias Evidence = SangakuSchemaV1.Evidence
typealias LeanResult = SangakuSchemaV1.LeanResult
typealias Alignment = SangakuSchemaV1.Alignment
typealias LeanDraft = SangakuSchemaV1.LeanDraft
typealias ComputeCell = SangakuSchemaV1.ComputeCell
