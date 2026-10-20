import Foundation

/// What every new prompt on a problem carries whatever the branch, in the order and the very words `ContextBuilder`
/// sends: the problem, notation, adopted lemmas, dead ends in context and refuted claims. Built from the same
/// snapshot and the same line functions, so the Branches summary cannot drift from what models are sent.
nonisolated struct PromptCarries: Hashable, Sendable {
    nonisolated struct Item: Hashable, Sendable, Identifiable {
        var id: UUID
        var title: String
        /// The line as sent.
        var line: String
    }

    var problemTitle: String
    var notationCount: Int
    var lemmas: [Item]
    var deadEnds: [Item]
    var refuted: [Item]

    /// Invariant 5: what may be left out, and what never is (`ContextBuilder`'s drop order).
    static let dropNote = "A model whose window is short is sent fewer earlier messages first, then fewer dead ends and lemmas, oldest first; what it was not sent is listed with the request. The problem, notation and refuted claims are always sent."

    init(_ snapshot: ProblemSnapshot) {
        problemTitle = snapshot.title
        notationCount = snapshot.notation.rows.filter(\.includeInContext).count
        lemmas = ContextBuilder.ordered(snapshot.adoptedLemmas).map {
            Item(id: $0.id, title: $0.label, line: ContextBuilder.lemmaLine($0))
        }
        deadEnds = ContextBuilder.ordered(snapshot.deadEnds).map {
            Item(id: $0.id, title: $0.name, line: ContextBuilder.deadEndLine($0))
        }
        refuted = snapshot.refutedClaims.map { Item(id: $0.id, title: $0.label, line: ContextBuilder.refutedLine($0)) }
    }
}
