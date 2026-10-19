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
}
