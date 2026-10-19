import SwiftUI

/// Lays cards out side by side in equal columns, as many as fit at `minColumnWidth`, and stacks them when the
/// column is narrow. Cards in a row are offered the row's height, so they can line up.
struct EqualColumnsLayout: Layout {
    var minColumnWidth: CGFloat = 250
    var spacing: CGFloat = 12

    func columns(for width: CGFloat, count: Int) -> Int {
        max(1, min(count, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        let rows = arrange(subviews, width: width)
        return CGSize(width: width, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      proposal: ProposedViewSize(width: row.columnWidth, height: row.height))
                x += row.columnWidth + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: Range<Int>
        var columnWidth: CGFloat
        var height: CGFloat
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        let columns = columns(for: width, count: subviews.count)
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            let indices = start..<min(start + columns, subviews.count)
            let height = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
            return Row(indices: indices, columnWidth: columnWidth, height: height)
        }
    }
}
