import Foundation

/// A local token estimate, made before sending so nothing leaves the Mac until Send. It errs high: prose is
/// counted at fewer bytes per token than the provider's tokenizer usually manages, and LaTeX markup, which tokenizes
/// densely, counts extra. Shown with ≈ and corrected by `TokenCalibration` once real counts exist.
nonisolated struct TokenEstimator: Hashable, Sendable {
    var bytesPerToken = 3.2
    /// Added per backslash, brace, script mark or dollar sign.
    var markupWeight = 0.3
    /// Role markers and framing around each block of a request.
    var perBlockOverhead = 4

    func tokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var bytes = 0
        var markup = 0
        for byte in text.utf8 {
            bytes += 1
            switch byte {
            case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "^"), UInt8(ascii: "_"),
                 UInt8(ascii: "$"):
                markup += 1
            default:
                break
            }
        }
        return Int((Double(bytes) / bytesPerToken + Double(markup) * markupWeight).rounded(.up))
    }

    /// A block's tokens including its framing.
    func blockTokens(_ text: String) -> Int {
        tokens(text) + perBlockOverhead
    }
}

/// How far actual counts have run from the estimates: the median of actual ÷ estimated over recent requests,
/// clamped so one odd request cannot swing it far.
nonisolated struct TokenCalibration: Hashable, Sendable {
    static let bounds = 0.5...2.0

    let ratio: Double

    init(ratio: Double = 1) {
        self.ratio = min(max(ratio, Self.bounds.lowerBound), Self.bounds.upperBound)
    }

    init(samples: [(estimated: Int, actual: Int)]) {
        let ratios = samples.filter { $0.estimated > 0 && $0.actual > 0 }
            .map { Double($0.actual) / Double($0.estimated) }
            .sorted()
        guard !ratios.isEmpty else { self.init(); return }
        let middle = ratios.count / 2
        let median = ratios.count.isMultiple(of: 2) ? (ratios[middle - 1] + ratios[middle]) / 2 : ratios[middle]
        self.init(ratio: median)
    }

    func apply(_ tokens: Int) -> Int {
        Int((Double(tokens) * ratio).rounded(.up))
    }
}
