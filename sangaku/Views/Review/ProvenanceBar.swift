import SwiftUI

/// Who wrote a step, from its revision history (invariant 7): one segment per author in the order they wrote, in
/// their colour. The letters or initials beside the step number carry the same information without colour.
struct ProvenanceBar: View {
    let marks: [AuthorDirectory.AuthorMark]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                RoundedRectangle(cornerRadius: 2)
                    .fill(mark.colorToken.color)
            }
        }
        .frame(width: 4)
        // The row's provenance line says the same in words.
        .accessibilityHidden(true)
    }

    /// The authors of a step's versions, consecutive repeats merged: A, then You, then A again is three segments.
    static func segments(_ versions: [StepProvenance.Version], authors: AuthorDirectory) -> [AuthorDirectory.AuthorMark] {
        var marks: [AuthorDirectory.AuthorMark] = []
        for version in versions {
            let mark = authors.mark(of: version.author)
            if marks.last != mark { marks.append(mark) }
        }
        return marks
    }
}

#if DEBUG
#Preview("Provenance bars", traits: .fixture) {
    let a = AuthorDirectory.AuthorMark(text: "A", colorToken: .modelA, name: "Model A")
    let you = AuthorDirectory.AuthorMark(text: "You", colorToken: .ink, name: "You")
    HStack(spacing: 16) {
        ProvenanceBar(marks: [a]).frame(height: 60)
        ProvenanceBar(marks: [a, you]).frame(height: 60)
        ProvenanceBar(marks: [a, you, a]).frame(height: 60)
    }
    .padding()
}
#endif
