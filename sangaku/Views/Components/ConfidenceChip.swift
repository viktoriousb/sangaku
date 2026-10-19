import SwiftUI

/// A model's own confidence label for a step. Shown, never used to skip or pass review (invariant 10).
struct ConfidenceChip: View {
    let confidence: Confidence

    var body: some View {
        Text(confidence.rawValue)
            .font(.caption)
            .foregroundStyle(confidence == .delicate ? ColorToken.delicate.color : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(confidence == .delicate ? ColorToken.delicateFill.color : Color.clear, in: .capsule)
            .overlay { Capsule().strokeBorder(.separator) }
            .fixedSize()
            .help("The model's own confidence: \(confidence.rawValue). It never stands in for a check.")
            .accessibilityLabel("Model's confidence: \(confidence.rawValue)")
    }
}

#if DEBUG
#Preview("Confidence chips") {
    VStack(alignment: .leading, spacing: 8) {
        HStack {
            ForEach(Confidence.allCases, id: \.self) { ConfidenceChip(confidence: $0) }
        }
    }
    .padding()
}
#endif
