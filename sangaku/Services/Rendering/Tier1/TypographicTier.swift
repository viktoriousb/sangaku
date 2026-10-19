import Foundation

/// Tier 1 in the renderer's chain. Inline only: display math always goes to the engine.
final class TypographicTier: MathTier {
    let name = "typographic"
    private let fontsAvailable: Bool

    init(fontsAvailable: Bool = FontRegistry.typographicFontsAvailable) {
        self.fontsAvailable = fontsAvailable
    }

    func render(_ request: MathRequest) -> TierOutcome {
        // Without STIX Two the text would fall back to another font silently; let the engine set it instead.
        guard fontsAvailable, request.style == .inline, let runs = TypographicMath.runs(for: request.latex) else {
            return .declined
        }
        return .rendered(.typographic(runs))
    }
}
