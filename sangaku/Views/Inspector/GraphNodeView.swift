import SwiftUI

/// One statement in the graph: its glyph and label, its displayed status, and a mark when something below holds it
/// down. Framed in the displayed status's border pattern (invariant 3), never the statement's own.
struct GraphNodeView: View {
    let node: StatementNode
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let style = StatusStyle.style(for: node.derived.displayed)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(verbatim: style.glyph)
                        .foregroundStyle(style.glyphToken.color)
                    Text(node.label).fontWeight(.semibold)
                }
                .font(.caption)
                Text(style.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let marker = Self.marker(for: node) {
                    Text(verbatim: marker.text)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(marker.mark.color)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
            .statusFrame(style, cornerRadius: 7)
            .overlay {
                // Selection is a second ring, a shape and not only a colour.
                if isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .inset(by: -3)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(node.accessibilityDescription)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete…", role: .destructive, action: onDelete)
                .disabled(node.isPinned)
            Divider()
            Button("Copy LaTeX Source") {
                Pasteboard.copy(node.statementLaTeX)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Edit", onEdit)
    }

    /// What the third line says, when anything: the first mark in words and the glyphs of any others, so a
    /// refuted dependency is never hidden by another mark.
    static func marker(for node: StatementNode) -> (text: String, mark: StatusMark)? {
        let marks = StatusMark.marks(for: node)
        guard let first = marks.first else { return nil }
        return (([first.glyph + " " + first.shortText] + marks.dropFirst().map(\.glyph)).joined(separator: " "), first)
    }
}
