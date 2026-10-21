import SwiftUI

/// One citation: its status as glyph and words, its text, struck through when no index has it, and a link only when a
/// matching document was found at an index's own https address (invariant 6).
struct CitationLine: View {
    let fact: CitationFact

    var body: some View {
        let style = StatusStyle.style(for: fact.status)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            StatusBadge(style: style, compact: true)
            if let link = fact.link {
                Link(destination: link) { Text(fact.text) }
                    .help("Opens the matching document at \(fact.indexName ?? "the index")")
            } else {
                Text(fact.text)
                    .strikethrough(style.strikesText)
                    .foregroundStyle(style.isProvisional ? ColorToken.secondaryInk.color : ColorToken.ink.color)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.label): \(fact.text)")
    }
}
