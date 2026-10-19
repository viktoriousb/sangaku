import Foundation

/// Sets formulas. Tier 1 (typographic text), then tier 2 (MicroTeX); a formula neither sets exactly becomes a
/// source chip (invariant 16). One instance for the app, used on the main actor; results are cached.
final class MathRenderer {
    nonisolated struct Key: Hashable, Sendable {
        var latex: String
        var macroFingerprint: String
        var sizeTenths: Int
        var style: MathStyle
    }

    private let tiers: [any MathTier]
    private var cache: GenerationalCache<Key, RenderedMath>

    init(tiers: [any MathTier], cacheCapacity: Int = 4_096) {
        self.tiers = tiers
        self.cache = GenerationalCache(capacity: cacheCapacity)
    }

    /// The renderer the app uses.
    static func standard() -> MathRenderer {
        MathRenderer(tiers: [TypographicTier(), MicroTeXTier()])
    }

    private(set) var cacheHits = 0

    /// Always returns something displayable: a rendering, or the source with the reason it was not rendered.
    func render(_ latex: String, context: MathContext, style: MathStyle) -> RenderedMath {
        let key = Key(latex: latex, macroFingerprint: context.macros.fingerprint,
                      sizeTenths: Int((context.fontSize * 10).rounded()), style: style)
        if let hit = cache[key] {
            cacheHits += 1
            return hit
        }
        let result = renderUncached(latex, context: context, style: style)
        cache[key] = result
        return result
    }

    private func renderUncached(_ latex: String, context: MathContext, style: MathStyle) -> RenderedMath {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .source(SourceChip(latex: latex, message: "Empty formula"))
        }
        let expanded: String
        switch context.macros.expand(trimmed) {
        case .success(let text): expanded = text
        case .failure(let error): return .source(SourceChip(latex: latex, message: error.message))
        }
        if let problem = TeXValidator.problem(in: expanded) {
            return .source(SourceChip(latex: latex, message: problem))
        }
        let request = MathRequest(latex: expanded, style: style, fontSize: context.fontSize)
        for tier in tiers {
            switch tier.render(request) {
            case .rendered(let rendered): return rendered
            case .declined: continue
            case .failed(let diagnostic): return .source(SourceChip(latex: latex, message: diagnostic.message))
            }
        }
        return .source(SourceChip(latex: latex, message: "No renderer accepts this formula"))
    }
}

/// A bounded cache in two generations: when the young one fills, it becomes the old one and the previous old
/// one is dropped. Hits in the old generation are promoted. Cheap, and keeps recently used entries.
struct GenerationalCache<Key: Hashable, Value> {
    private var young: [Key: Value] = [:]
    private var old: [Key: Value] = [:]
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    subscript(key: Key) -> Value? {
        mutating get {
            if let value = young[key] { return value }
            if let value = old.removeValue(forKey: key) {
                insert(value, for: key)
                return value
            }
            return nil
        }
        set {
            if let newValue { insert(newValue, for: key) } else { young[key] = nil; old[key] = nil }
        }
    }

    private mutating func insert(_ value: Value, for key: Key) {
        if young.count >= capacity {
            old = young
            young = [:]
        }
        young[key] = value
    }

    var count: Int { young.count + old.count }
}
