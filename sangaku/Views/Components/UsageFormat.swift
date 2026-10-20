import Foundation

/// Token counts and costs as the thread, the composer and View context show them.
enum UsageFormat {
    static func tokens(_ count: Int) -> String {
        count < 1000 ? "\(count)" : count < 100_000
            ? String(format: "%.1fK", Double(count) / 1000) : "\(Int((Double(count) / 1000).rounded()))K"
    }

    static func cost(_ dollars: Double) -> String {
        dollars >= 1 ? String(format: "$%.2f", dollars) : dollars >= 0.01 ? String(format: "$%.3f", dollars)
            : String(format: "$%.4f", dollars)
    }

    /// An input cost before sending: a range while it is unknown whether the cache is read or written, else a
    /// figure. Nil when the model's price is unknown.
    static func cost(_ cost: SendPlan.Cost) -> String? {
        switch cost {
        case .range(let low, let high): "\(Self.cost(low))–\(Self.cost(high))"
        case .single(let value): Self.cost(value)
        case .unknown: nil
        }
    }

    /// One request's estimate, as both the composer and Compare say it: the input size, its cost, and the most the
    /// output can cost; output length is not guessed. `model` names the model whose price is unknown, where it may be
    /// named.
    static func estimate(tokens count: Int?, cost: SendPlan.Cost, outputCeiling: Double?, each: Bool = false,
                         model: String?) -> [String] {
        var parts: [String] = []
        if let count { parts.append("≈ \(tokens(count)) tokens in" + (each ? " each" : "")) }
        let unknown = "price unknown for " + (model.flatMap { $0.isEmpty ? nil : $0 } ?? "this model")
        parts.append(Self.cost(cost).map { "≈ \($0) input" } ?? unknown)
        if let outputCeiling { parts.append("output at most \(Self.cost(outputCeiling))") }
        return parts
    }
}
