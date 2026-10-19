import Foundation

nonisolated extension ReviewVerdict {
    var glyph: String {
        switch self {
        case .correct: "✓"
        case .wrong: "✗"
        case .unclear: "?"
        }
    }

    var title: String {
        switch self {
        case .correct: "Correct"
        case .wrong: "Wrong"
        case .unclear: "Unclear"
        }
    }

    /// "Step 4 marked correct", for announcements.
    var pastTense: String {
        switch self {
        case .correct: "marked correct"
        case .wrong: "marked wrong"
        case .unclear: "flagged as unclear"
        }
    }
}
