import Foundation

/// What a row asks Compare to do. Each carries the values the row showed, the pair included, so the handler reads
/// nothing from the render it was made in.
nonisolated enum CompareIntent: Sendable {
    /// Make the row current.
    case focus(RowKey)
    /// Pair two steps: `a` of Attempt 1 with `b` of Attempt 2.
    case pair(RowKey, in: ComparedPair)
    case unpair(CompareRow, in: ComparedPair)
    case judge(CompareRow, AlignmentVerdict, in: ComparedPair)
    /// Withdraw the person's judgement of the row.
    case clear(CompareRow, in: ComparedPair)

    /// The row the action was taken on, where its outcome is shown.
    var row: RowKey {
        switch self {
        case .focus(let key), .pair(let key, _): key
        case .unpair(let row, _), .judge(let row, _, _), .clear(let row, _): row.id
        }
    }
}

/// What came of an action, shown where it was taken: under its row, or in the resolve panel when `row` is nil.
nonisolated struct CompareNotice: Equatable, Sendable {
    var row: RowKey?
    var text: String
    var isError: Bool
}

/// What the Compare menu asks of the key window's Compare.
nonisolated enum CompareMenuCommand: Sendable {
    case next, previous, align
}

/// The Compare menu's handle on the key window's Compare. Compared by everything its closure reads (the rows in
/// order, the current row, whether aligning is possible), so the closure is never older than what the menu acts on.
nonisolated struct CompareControl: Equatable, Sendable {
    let presenter: UUID
    let rows: [RowKey]
    let current: RowKey?
    let canAlign: Bool
    let perform: @MainActor (CompareMenuCommand) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presenter == rhs.presenter && lhs.rows == rhs.rows && lhs.current == rhs.current
            && lhs.canAlign == rhs.canAlign
    }

    @MainActor func callAsFunction(_ command: CompareMenuCommand) { perform(command) }
}
