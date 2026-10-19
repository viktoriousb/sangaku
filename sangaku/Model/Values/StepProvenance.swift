import Foundation

/// Who wrote a step's text, read from its revision history (invariant 7): the margin bar and the history list.
nonisolated struct StepProvenance: Hashable, Sendable {
    nonisolated struct Version: Hashable, Sendable, Identifiable {
        var id: UUID
        /// 1 for the first version.
        var number: Int
        var createdAt: Date
        var author: Author?
        var textLaTeX: String
        var establishes: String
        var changedText: Bool
        var changedEstablishes: Bool
        var isCurrent: Bool
    }

    /// Oldest first.
    var versions: [Version]

    init(revisions: [RevisionFact]) {
        let ordered = revisions.sorted(by: RevisionFact.precedes)
        versions = ordered.enumerated().map { offset, revision in
            let previous = offset > 0 ? ordered[offset - 1] : nil
            return Version(
                id: revision.id, number: offset + 1, createdAt: revision.createdAt, author: revision.author,
                textLaTeX: revision.textLaTeX, establishes: revision.establishes,
                changedText: previous.map { $0.textLaTeX != revision.textLaTeX } ?? false,
                changedEstablishes: previous.map {
                    StepStandings.normalized($0.establishes) != StepStandings.normalized(revision.establishes)
                } ?? false,
                isCurrent: offset == ordered.count - 1)
        }
    }

    var current: Version? { versions.last }
    var original: Version? { versions.first }
    var isRevised: Bool { versions.count > 1 }

    /// The current text's author, when it was revised by a person: what models are told.
    var revisingPerson: Author? {
        guard isRevised, let author = current?.author, author.isHuman else { return nil }
        return author
    }
}
