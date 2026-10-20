import Foundation

/// Why a change to a comparison was refused. Every refusal leaves the store unchanged.
nonisolated enum CompareError: Error, Hashable, Sendable {
    case noSuchAttempt
    /// The same attempt twice, or attempts of different problems.
    case notAPair
    case stepNotInAttempt
    case notPaired
    /// A step was revised after the person read it: what they judged is no longer the text.
    case staleRevision
    /// A step has no recorded revision, so nothing would say which text a judgement covers.
    case noRevision
    /// The stored corrections cannot be read; writing would lose them.
    case correctionsUnreadable
    /// A verdict is stored, readable or not; it is never written over.
    case verdictAlreadyRecorded
    /// The slot is not a referee, or wrote one of the attempts: a slot never aligns its own work.
    case noAligner

    var message: String {
        switch self {
        case .noSuchAttempt: "That attempt is no longer in this problem."
        case .notAPair: "Choose two different attempts of the same problem."
        case .stepNotInAttempt: "That step is not in either attempt."
        case .notPaired: "Those steps are not paired."
        case .staleRevision: "A step changed after you read it. Read the new version, then decide again."
        case .noRevision: "A step without a recorded revision cannot be judged: nothing would say which text you judged."
        case .correctionsUnreadable: "The corrections stored for this comparison cannot be read, so nothing is written over them."
        case .verdictAlreadyRecorded: "A verdict is already recorded for this comparison."
        case .noAligner: "No model can align these attempts. Make a model that wrote neither attempt a referee first."
        }
    }
}
