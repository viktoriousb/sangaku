import Foundation

/// The one rule for what models are told about a dead end, and a person's edit of a branch's two texts.
nonisolated enum BranchReasons {
    static let noReason = "(no reason recorded)"

    /// The text written for models, else the reason written for people, else "(no reason recorded)".
    static func textForModels(forModels: String?, forPeople: String?) -> String {
        trimmed(forModels) ?? trimmed(forPeople) ?? noReason
    }

    /// The text without surrounding white space, or nil when nothing is left.
    static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// A person's edit of a branch's reasons, as the reason sheet holds it before saving. Both texts are typed or copied
/// in by a person; no model writes or drafts them.
nonisolated struct ReasonDraft: Hashable, Sendable {
    enum Field: Hashable, Sendable { case people, models }

    /// "Why it died", for people; LaTeX allowed.
    var reason = ""
    /// The exact text sent to models; empty means the reason for people is sent.
    var reasonForModels = ""
    /// A dead end's reason goes into every prompt; on by default when a branch is marked a dead end.
    var includeInContext = true
    /// The message each text was started from, if any.
    var reasonFromMessageID: UUID?
    var modelTextFromMessageID: UUID?

    /// What models would be told.
    var textForModels: String {
        BranchReasons.textForModels(forModels: reasonForModels, forPeople: reason)
    }

    /// Whether either text says anything.
    var hasText: Bool {
        BranchReasons.trimmed(reason) != nil || BranchReasons.trimmed(reasonForModels) != nil
    }

    /// Starts a text from a message's text, recording which message it came from.
    mutating func start(_ field: Field, from text: String, messageID: UUID) {
        switch field {
        case .people:
            reason = text
            reasonFromMessageID = messageID
        case .models:
            reasonForModels = text
            modelTextFromMessageID = messageID
        }
    }

    /// Why this draft cannot be saved for a branch in `state`, or nil. Shared by the sheet and `BranchManager`.
    func refusal(for state: BranchState) -> BranchError? {
        state == .deadEnd && includeInContext && !hasText ? .reasonRequired : nil
    }
}
