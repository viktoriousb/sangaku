import AppKit
import Foundation

nonisolated enum MathStyle: Hashable, Sendable {
    case inline, display
}

/// Everything a formula's appearance depends on besides its source: the problem's macros and the size.
/// Travels through the environment, one per problem.
nonisolated struct MathContext: Equatable, Sendable {
    var macros: MacroSet
    var fontSize: Double

    init(macros: MacroSet = .empty, fontSize: Double = 16) {
        self.macros = macros
        self.fontSize = fontSize
    }
}

/// What a tier is asked to set: macro-expanded source.
nonisolated struct MathRequest: Hashable, Sendable {
    var latex: String
    var style: MathStyle
    var fontSize: Double
}

nonisolated struct MathDiagnostic: Error, Hashable, Sendable {
    var message: String
}

/// A formula no tier could set exactly, shown as its source with the reason (invariant 16).
nonisolated struct SourceChip: Hashable, Sendable {
    var latex: String
    var message: String
}

/// A typeset formula from tier 2: a template image whose baseline sits `descent` above its bottom edge.
struct MathImage {
    let image: NSImage
    let size: CGSize
    let descent: Double
}

/// The only three ways a formula can appear. There is deliberately no case for an approximation.
enum RenderedMath {
    case typographic([MathRun])
    case image(MathImage)
    case source(SourceChip)

    var tierName: String {
        switch self {
        case .typographic: "typographic"
        case .image: "engine"
        case .source: "source"
        }
    }
}

enum TierOutcome {
    case rendered(RenderedMath)
    /// Not this tier's kind of formula; try the next.
    case declined
    /// This tier should have set the formula but could not; show the source with this reason.
    case failed(MathDiagnostic)
}

protocol MathTier: AnyObject {
    var name: String { get }
    func render(_ request: MathRequest) -> TierOutcome
}
