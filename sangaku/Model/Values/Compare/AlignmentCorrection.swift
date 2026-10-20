import Foundation

/// One change a person made to a comparison: pairing two steps, separating them, or judging a pair. Kept as an
/// append-only log beside the model's rows and replayed over them on every read, so a new model alignment never
/// erases what a person decided.
nonisolated struct AlignmentCorrection: Codable, Hashable, Sendable {
    nonisolated enum Action: String, Codable, Hashable, Sendable, CaseIterable {
        /// Pair the two steps, taking each out of any row it was in.
        case pair
        /// Separate the two steps: each then stands alone unless paired again by hand.
        case unpair
        /// Judge the pair equivalent or diverging, on the revisions the person read.
        case judge
        /// Withdraw the person's judgement of the pair.
        case clear
    }

    var action: Action
    /// The step of side 1 (`Alignment.attemptAID`) and of side 2.
    var stepAID: UUID
    var stepBID: UUID
    /// For `judge`: "equivalent" or "diverge". Anything else reads as diverge.
    var verdict: String?
    var revisionAID: UUID?
    var revisionBID: UUID?
    var personID: UUID?
    var at: Date

    var key: RowKey { RowKey(a: stepAID, b: stepBID) }
}

/// A row's identity: the step of each side it holds.
nonisolated struct RowKey: Hashable, Sendable, Codable {
    var a: UUID?
    var b: UUID?
}
