import Foundation

/// How the Branches screen is laid out: the panel beside the tree where both fit, else everything stacked.
nonisolated enum BranchesLayoutMode: Hashable, Sendable {
    case sideBySide, stacked

    static let panelWidth: Double = 340
    /// The narrowest content width the tree and the panel are drawn side by side at.
    static let sideBySideMinimumWidth: Double = 720

    static func resolve(width: Double) -> BranchesLayoutMode {
        width >= sideBySideMinimumWidth ? .sideBySide : .stacked
    }
}
