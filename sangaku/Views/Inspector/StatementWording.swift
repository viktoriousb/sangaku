import Foundation

/// What the inspector and the statement editor say about a statement, kept out of the views so it is tested.
enum StatementWording {
    /// Under the source of an imported statement in the editor.
    static let importedCaption = "It has no proof here and counts as imported, not checked. What uses it is not held down by it, but says that it assumes it."

    /// The inspector's line for an imported statement.
    static func imported(_ source: String) -> String {
        "Imported from " + source + ". Not proved or checked here."
    }
}
