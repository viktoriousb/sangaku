import Foundation

/// US dollars per million tokens.
nonisolated struct Pricing: Hashable, Sendable {
    var inputPerMTok: Double
    var outputPerMTok: Double
    var cacheReadPerMTok: Double
    /// The 5-minute cache write.
    var cacheWritePerMTok: Double
}

nonisolated struct ModelInfo: Hashable, Identifiable, Sendable {
    var id: String
    var providerID: String
    var displayName: String
    var contextWindow: Int
    var maxOutputTokens: Int
    /// A stable part shorter than this is not cached by the provider.
    var minimumCacheablePrefix: Int
    var pricing: Pricing
}

/// A model ID looked up in the catalog. An unknown ID stays visibly unknown: no window, no price, never 0.
nonisolated enum ModelResolution: Hashable, Sendable {
    case known(ModelInfo)
    case unknown(String)

    var info: ModelInfo? {
        if case .known(let info) = self { info } else { nil }
    }

    var modelID: String {
        switch self {
        case .known(let info): info.id
        case .unknown(let id): id
        }
    }

    var displayName: String {
        switch self {
        case .known(let info): info.displayName
        case .unknown(let id): id.isEmpty ? "unknown model" : id
        }
    }
}

/// The models the app offers, with their prices.
nonisolated struct ModelCatalog: Sendable {
    /// When the prices below were taken from the provider's price list.
    static let pricesAsOf = "2026-10-06"

    static let claudeOpus55 = ModelInfo(
        id: "claude-opus-5-5", providerID: ProviderID.anthropic, displayName: "Claude Opus 5.5",
        contextWindow: 1_000_000, maxOutputTokens: 128_000, minimumCacheablePrefix: 512,
        pricing: Pricing(inputPerMTok: 4, outputPerMTok: 20, cacheReadPerMTok: 0.20, cacheWritePerMTok: 5))

    static let standard = ModelCatalog(models: [claudeOpus55])

    let models: [ModelInfo]

    func resolve(_ modelID: String) -> ModelResolution {
        models.first { $0.id == modelID }.map(ModelResolution.known) ?? .unknown(modelID)
    }

    /// The model a new slot for this provider gets.
    func defaultModel(for providerID: String) -> ModelInfo? {
        models.first { $0.providerID == providerID }
    }

    /// The models a slot of this provider can be set to.
    func models(for providerID: String) -> [ModelInfo] {
        models.filter { $0.providerID == providerID }
    }

    /// The cost of a request in US dollars, or nil when the model's price is unknown.
    static func cost(_ usage: TokenUsage, _ resolution: ModelResolution) -> Double? {
        guard let pricing = resolution.info?.pricing else { return nil }
        return (Double(usage.input) * pricing.inputPerMTok
            + Double(usage.cacheWrite) * pricing.cacheWritePerMTok
            + Double(usage.cacheRead) * pricing.cacheReadPerMTok
            + Double(usage.output) * pricing.outputPerMTok) / 1_000_000
    }
}
