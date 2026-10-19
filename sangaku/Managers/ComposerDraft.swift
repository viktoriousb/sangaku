import Foundation

/// The composer's draft for one branch. Held by `ThreadManager` for the session, so it survives switching views
/// and problems. Typing changes only this object.
@Observable
final class ComposerDraft {
    var text = ""
    var effort = ThinkingEffort.standard
    /// The recipients, visibility and referee. Sending clears the text and keeps these.
    var selection = SendSelection()
}
