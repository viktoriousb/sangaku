import Foundation

/// How the Review screen is laid out: the verification panel beside the steps where both fit, else below them.
nonisolated enum ReviewLayoutMode: Hashable, Sendable {
    case sideBySide, stacked

    static let panelWidth: Double = 340
    static let gap: Double = 16
    /// The narrowest the steps are read beside the panel.
    static let minimumStepsWidth: Double = 520

    static func resolve(width: Double) -> ReviewLayoutMode {
        width >= minimumStepsWidth + gap + panelWidth ? .sideBySide : .stacked
    }
}
