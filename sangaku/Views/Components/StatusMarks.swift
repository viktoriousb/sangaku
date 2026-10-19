import SwiftUI

/// The marks a statement can carry besides its status: each a glyph with words, never colour alone (invariant 3).
enum StatusMark: CaseIterable {
    case refutedDependency, cycle, capped

    var glyph: String {
        switch self {
        case .refutedDependency: StatusStyle.style(for: .refuted).glyph
        case .cycle: "↻"
        case .capped: "↓"
        }
    }

    /// The words on a box of the graph.
    var shortText: String {
        switch self {
        case .refutedDependency: "Uses refuted"
        case .cycle: "In a cycle"
        case .capped: "Capped"
        }
    }

    /// The words in the legend.
    var legend: String {
        switch self {
        case .refutedDependency: "Depends on a refuted claim"
        case .cycle: "Its dependencies form a cycle"
        case .capped: "Capped: something it uses has a lower status"
        }
    }

    var color: Color { self == .refutedDependency ? ColorToken.refuted.color : .secondary }

    /// The marks a statement carries, the refuted dependency first: it must always be visible (invariant 13). A
    /// refuted dependency or a cycle already says why the status is low, so "capped" is then left out.
    static func marks(for node: StatementNode) -> [StatusMark] {
        var marks: [StatusMark] = []
        if node.derived.dependsOnRefuted { marks.append(.refutedDependency) }
        if node.derived.isUnresolved { marks.append(.cycle) }
        if marks.isEmpty, node.derived.isCapped { marks.append(.capped) }
        return marks
    }
}

/// Why a statement shows a lower status than its own: a line per reason, with its mark's glyph.
struct StatusExplanationLines: View {
    let explanation: StatusExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let caps = explanation.caps { line(caps, .capped) }
            if let refuted = explanation.refutedDependency { line(refuted, .refutedDependency) }
            if let cycle = explanation.cycle { line(cycle, .cycle) }
        }
    }

    private func line(_ text: String, _ mark: StatusMark) -> some View {
        Label {
            Text(text)
        } icon: {
            Text(verbatim: mark.glyph)
        }
        .font(.caption)
        .foregroundStyle(mark.color)
        .fixedSize(horizontal: false, vertical: true)
    }
}
