import AppKit

/// Tier 2 in the renderer's chain: everything tier 1 declines, set by MicroTeX as a vector template image.
final class MicroTeXTier: MathTier {
    let name = "MicroTeX"
    private let typesetter: MicroTeXTypesetter

    init(typesetter: MicroTeXTypesetter = .shared) {
        self.typesetter = typesetter
    }

    func render(_ request: MathRequest) -> TierOutcome {
        let source = MicroTeXCompat.rewrite(request.latex)
        switch typesetter.typeset(source, fontSize: request.fontSize, display: request.style == .display) {
        case .failure(let diagnostic):
            return .failed(diagnostic)
        case .success(let formula):
            let size = CGSize(width: max(1, ceil(formula.width)), height: max(1, ceil(formula.ascent + formula.descent)))
            return .rendered(.image(MathImage(image: Self.image(drawing: formula.ops, size: size), size: size,
                                              descent: formula.descent)))
        }
    }

    /// A vector template image: the handler runs at whatever scale, and on whatever thread, AppKit draws it.
    /// Built outside the main actor so the handler carries no main-actor isolation to trap on.
    nonisolated private static func image(drawing ops: [DrawOp], size: CGSize) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            DrawOpReplay.draw(ops, in: context)
            return true
        }
        image.isTemplate = true
        return image
    }
}
