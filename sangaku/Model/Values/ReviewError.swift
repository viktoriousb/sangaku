import Foundation

/// Why a review action was refused. Every refusal leaves the store unchanged.
nonisolated enum ReviewError: Error, Hashable, Sendable {
    case noSuchStep
    case noSuchReview
    case noRevision
    /// The step was revised after the person opened it: what they saw is no longer current.
    case staleRevision
    case notYourReview
    /// Only a mark made since the app opened, with nothing recorded on its step after it, is undone outright.
    case cannotUndo
    case notAnObjection
    /// The objection is already closed, by a dismissal, a withdrawal or a newer revision.
    case notOpen
    case reasonRequired
    case emptyText
    case nothingChanged
    case emptyComment
    case noSuchRevision

    var message: String {
        switch self {
        case .noSuchStep: "That step is no longer in this problem."
        case .noSuchReview: "That review is no longer there."
        case .noRevision: "This step has no recorded text to review."
        case .staleRevision: "This step was revised after you opened it. Read the new version, then decide again."
        case .notYourReview: "Only the person who gave a mark can withdraw it. Dismiss an objection with a reason instead."
        case .cannotUndo: "This mark can no longer be undone: it was made before sangaku opened, or something was recorded on the step since. Withdraw it instead."
        case .notAnObjection: "Only a ✗ or ? can be dismissed."
        case .notOpen: "That objection is already closed."
        case .reasonRequired: "Give a reason for closing the objection."
        case .emptyText: "Write the step."
        case .nothingChanged: "Nothing changed, so no new version was made."
        case .emptyComment: "Write the comment."
        case .noSuchRevision: "That version of the step is no longer there."
        }
    }
}
