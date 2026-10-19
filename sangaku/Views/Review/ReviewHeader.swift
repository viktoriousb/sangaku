import SwiftData
import SwiftUI

/// The theorem, the attempt under review, how many of its steps a person has checked, and who the margin colours
/// stand for.
struct ReviewHeader: View {
    let theorem: StatementNode?
    let options: [ReviewAttemptOption]
    let chosen: UUID
    let progress: ReviewProgress
    let legend: [AuthorDirectory.AuthorMark]
    let authors: AuthorDirectory
    /// The label of the statement whose steps Review was opened for.
    var highlight: String?
    let onChoose: @MainActor (UUID) -> Void
    let onClearHighlight: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let theorem {
                VStack(alignment: .leading, spacing: 4) {
                    Text(theorem.label).font(.headline)
                    MathText(theorem.statementLaTeX)
                }
            }
            FlowLayout(spacing: 16, lineSpacing: 8) {
                Picker("Attempt", selection: Binding(get: { chosen }, set: onChoose)) {
                    ForEach(options) { option in
                        Text(label(option)).tag(option.id)
                    }
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.headline)
                        .font(.callout.weight(.semibold))
                    if !progress.notes.isEmpty {
                        Text(progress.notes.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            ProgressView(value: Double(progress.checked), total: Double(max(progress.total, 1)))
                .accessibilityHidden(true)
            FlowLayout(spacing: 10, lineSpacing: 4) {
                Text("Margin shows who wrote each step:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(legend, id: \.self) { mark in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(mark.colorToken.color)
                            .frame(width: 4, height: 12)
                        Text("\(mark.text) \(mark.text == mark.name ? "" : mark.name)")
                            .font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let highlight {
                HStack(spacing: 8) {
                    Label("Showing the steps of \(highlight)", systemImage: "scope")
                        .font(.callout)
                    Button("Clear", action: onClearHighlight)
                }
            }
        }
    }

    /// "Model A · 11:02 · 6 steps", marked when partial.
    private func label(_ option: ReviewAttemptOption) -> String {
        [authors.name(of: option.author), ReviewTime.text(option.createdAt), Prose.count(option.stepCount, "step"),
         option.isPartial ? "partial" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

#if DEBUG
#Preview("Review header", traits: .fixture, .fixedLayout(width: 640, height: 260)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Environment(\.statementGraph) var graph
    ReviewPreviewData { state, authors in
        ReviewHeader(theorem: problems.first.flatMap { graph?.state(for: $0).pinned },
                     options: [], chosen: state.attemptID, progress: state.progress,
                     legend: ReviewWording.legend(state, authors: authors), authors: authors, highlight: "Lem 3",
                     onChoose: { _ in }, onClearHighlight: {})
            .padding()
    }
}
#endif
