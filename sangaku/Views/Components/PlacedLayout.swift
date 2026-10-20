import SwiftUI

/// Places each subview at the rectangle it carries in `SlotRect`, in a fixed size: the inspector's graph and the
/// Branches tree, whose positions a pure placement computes.
struct PlacedLayout: Layout {
    let size: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let rect = subview[SlotRect.self]
            subview.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                          proposal: ProposedViewSize(rect.size))
        }
    }
}

/// Where `PlacedLayout` puts a subview.
nonisolated struct SlotRect: LayoutValueKey {
    static let defaultValue = CGRect.zero
}
