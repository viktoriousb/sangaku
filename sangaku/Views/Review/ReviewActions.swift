import Foundation

/// What a row asks Review to do. Each carries the values the row showed, so the handler never reads a stale
/// render: a verdict is given on the revision the person saw.
nonisolated enum ReviewIntent: Sendable {
    /// Make the step current.
    case focus(UUID)
    case mark(StepReview, ReviewVerdict)
    case withdraw(StepReview, ReviewFact)
    case dismiss(StepReview, ReviewFact)
    case revise(StepReview)
    case comment(StepReview)
    /// Undo the mark just made on the step (Edit > Undo).
    case undo(StepReview)
}

/// What a row says after an action on it: a refusal, or a confirmation that may offer Undo.
nonisolated struct ReviewRowNotice: Hashable, Sendable {
    var message: String
    var isError: Bool
    var canUndo = false
}

/// What the Review menu can ask of the Review in the key window.
nonisolated enum ReviewMenuCommand: Sendable {
    case command(ReviewCommand)
    case revise
}

/// The Review menu's handle on the key window's Review. Compared by what the menu shows; the closure reads the
/// store afresh, so it does not matter which render made it.
nonisolated struct ReviewControl: Equatable, Sendable {
    let presenter: UUID
    let attemptID: UUID
    let currentStepID: UUID?
    let hasSteps: Bool
    let perform: @MainActor (ReviewMenuCommand) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presenter == rhs.presenter && lhs.attemptID == rhs.attemptID && lhs.currentStepID == rhs.currentStepID
            && lhs.hasSteps == rhs.hasSteps
    }

    @MainActor func callAsFunction(_ command: ReviewMenuCommand) { perform(command) }
}
