import SwiftUI

extension EnvironmentValues {
    /// The app's one `MathRenderer`. Optional so a missing injection shows as a visible source chip in
    /// `MathText` instead of failing silently.
    @Entry var mathRenderer: MathRenderer? = nil
    /// Macros and size for the problem being shown.
    @Entry var mathContext: MathContext = MathContext()
    @Entry var problemManager: ProblemManager? = nil
    @Entry var saveScheduler: SaveScheduler? = nil
    @Entry var threadManager: ThreadManager? = nil
    @Entry var statementGraph: StatementGraph? = nil
    @Entry var reviewManager: ReviewManager? = nil
    @Entry var alignmentService: AlignmentService? = nil
    /// Opens the promote sheet for steps of finished attempts. Unset where steps cannot be promoted.
    @Entry var promoteSteps: PromoteStepsAction? = nil
    /// Opens Review on an attempt or a step. Unset where Review cannot be opened.
    @Entry var openReview: OpenReviewAction? = nil
    /// Opens Compare on a fan-out's attempts. Unset where Compare cannot be opened.
    @Entry var openCompare: OpenCompareAction? = nil
    /// Compare's handler for its rows.
    @Entry var compareActions: CompareActions? = nil
    /// Review's handler for its rows.
    @Entry var reviewActions: ReviewActions? = nil
    @Entry var credentialManager: CredentialManager? = nil
    /// Overrides the system's accessibility display settings (previews and tests).
    @Entry var statusAccessibilityOverride: StatusAccessibility? = nil
}

extension FocusedValues {
    /// The key window's state, for menu commands.
    @Entry var windowState: WindowState? = nil
    /// The key window's Review, for the Review menu.
    @Entry var reviewControl: ReviewControl? = nil
    /// The key window's Compare, for the Compare menu.
    @Entry var compareControl: CompareControl? = nil
}

/// An action a view hands down through the environment. Compared by the view that presents it, not by the closure,
/// so a re-render of the presenter does not invalidate every row. The closure must therefore read nothing from the
/// render it was made in: what it acts on comes in as `Input`.
nonisolated struct PresentedAction<Input: Sendable>: Equatable, Sendable {
    let presenter: UUID
    let perform: @MainActor (Input) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.presenter == rhs.presenter }

    @MainActor func callAsFunction(_ input: Input) { perform(input) }
}

/// Opens the promote sheet.
typealias PromoteStepsAction = PresentedAction<PromotionTarget>
/// Opens Review.
typealias OpenReviewAction = PresentedAction<ReviewTarget>
/// Review's handler for its rows.
typealias ReviewActions = PresentedAction<ReviewIntent>
/// Opens Compare.
typealias OpenCompareAction = PresentedAction<CompareTarget>
/// Compare's handler for its rows.
typealias CompareActions = PresentedAction<CompareIntent>
