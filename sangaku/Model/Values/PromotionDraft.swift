import Foundation

/// What the promote sheet opens on: one attempt and the step clicked, or a referee's attempts with no step chosen.
nonisolated struct PromotionTarget: Identifiable, Hashable, Sendable {
    var attemptIDs: [UUID]
    var stepID: UUID?

    /// Equal targets are the same request, so a step row that is drawn again compares equal.
    var id: Self { self }
}

/// The promote sheet's choices, kept apart from the store until Promote is pressed.
nonisolated struct PromotionDraft: Hashable, Sendable {
    var attemptID: UUID
    private(set) var firstIndex: Int
    private(set) var lastIndex: Int
    private(set) var kind: StatementKind = .lemma
    private(set) var label: String
    private(set) var statementLaTeX: String
    var uses: Set<UUID> = []
    var usedByPinned = true
    /// Once a person types a label or a statement, choosing other steps or another kind no longer replaces it.
    private(set) var labelEdited = false
    private(set) var textEdited = false

    /// `texts` holds the attempt's step texts by index.
    init(attemptID: UUID, first: Int, last: Int, existingLabels: [String], texts: [Int: String]) {
        self.attemptID = attemptID
        firstIndex = min(first, last)
        lastIndex = max(first, last)
        label = StatementLabels.next(for: .lemma, existing: existingLabels)
        statementLaTeX = ""
        statementLaTeX = Self.prefill((firstIndex...lastIndex).compactMap { texts[$0] })
    }

    var run: ClosedRange<Int> { firstIndex...lastIndex }

    /// The steps' text, as a start for the statement: a step is proof, not yet a statement.
    static func prefill(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func chooseRun(first: Int, last: Int, texts: [Int: String]) {
        firstIndex = min(first, last)
        lastIndex = max(first, last)
        if !textEdited { statementLaTeX = Self.prefill(run.compactMap { texts[$0] }) }
    }

    mutating func chooseKind(_ kind: StatementKind, existingLabels: [String]) {
        self.kind = kind
        if !labelEdited { label = StatementLabels.next(for: kind, existing: existingLabels) }
    }

    mutating func editLabel(_ label: String) {
        self.label = label
        labelEdited = true
    }

    mutating func editText(_ text: String) {
        statementLaTeX = text
        textEdited = true
    }
}
