import SwiftUI

/// The title, which attempts are compared, the filter, blind mode, the summary and the alignment request.
struct CompareHeader: View {
    let options: [AttemptOption]
    let chosen: (UUID, UUID)
    let state: ComparisonState
    let identity: CompareIdentity
    let run: CompareRunInfo
    let window: WindowState
    let onAlign: @MainActor () -> Void
    let onStop: @MainActor () -> Void
    let onViewContext: @MainActor (RequestRecord) -> Void

    var body: some View {
        @Bindable var window = window
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(CompareWording.title).font(.title2.weight(.semibold))
                Text(CompareWording.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 12, lineSpacing: 8) {
                if identity.hidden {
                    // Picking by time or author would tell which attempt is which.
                    Text("Comparing \(CompareWording.attempt(1)) and \(CompareWording.attempt(2))")
                        .font(.callout)
                } else {
                    Picker("Compare", selection: Binding(get: { chosen.0 }, set: { pick($0, keeping: chosen.1) })) {
                        ForEach(options) { Text(identity.attemptLabel($0)).tag($0.id) }
                    }
                    .fixedSize()
                    Picker("with", selection: Binding(get: { chosen.1 }, set: { pick($0, keeping: chosen.0) })) {
                        ForEach(options) { Text(identity.attemptLabel($0)).tag($0.id) }
                    }
                    .fixedSize()
                }
                Picker("Show", selection: $window.compareFilter) {
                    Text("All Steps").tag(CompareFilter.all)
                    Text("Differences Only").tag(CompareFilter.differences)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("Blind Mode", isOn: $window.blindMode)
                    .toggleStyle(.switch)
                    .help("Hide who wrote each attempt until you record which holds (⌘⇧B)")
            }
            FlowLayout(spacing: 6, lineSpacing: 4) {
                ForEach(Array(CompareWording.chips(state.summary).enumerated()), id: \.offset) { _, style in
                    StatusBadge(style: style)
                }
            }
            status
            if state.modelRowsUnreadable {
                Label("The stored alignment cannot be read; the steps are paired by label until it is aligned again.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(ColorToken.refuted.color)
            }
            if state.correctionsUnreadable {
                Label("Your corrections stored for this comparison cannot be read; they are not shown, and nothing writes over them.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(ColorToken.refuted.color)
            }
            Text(CompareWording.neverACheck)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The alignment request: running, done, failed, or not yet made.
    @ViewBuilder private var status: some View {
        FlowLayout(spacing: 10, lineSpacing: 6) {
            if run.aligningRecordID != nil {
                ProgressView().controlSize(.small)
                Text("Aligning with \(run.alignerName)…").font(.callout)
                Button("Stop", action: onStop)
            } else {
                Text(CompareWording.status(hasModelRows: state.hasModelRows, alignedAt: run.alignedRecord?.createdAt,
                                           aligner: run.alignerName))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(state.hasModelRows ? "Align Again…" : "Align…", action: onAlign)
                    .help("Ask a model to pair the steps and judge each row; your corrections are kept")
                if let record = run.alignedRecord, !identity.hidden {
                    Button("View Context") { onViewContext(record) }
                }
            }
        }
        if let problem = run.lastProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(ColorToken.refuted.color)
        }
        if !run.summary.isEmpty {
            MathText(run.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func pick(_ id: UUID, keeping other: UUID) {
        let keep = id == other ? (options.first { $0.id != id }?.id ?? other) : other
        window.chooseCompare([id, keep])
    }
}

/// A column heading: the attempt, its author once the authors may be shown, and whether it stopped early.
struct CompareSideHeading: View {
    let side: Int
    let identity: CompareIdentity
    let partial: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let mark = identity.mark(side) {
                AuthorBadge(text: mark.text, colorToken: mark.colorToken)
            }
            Text(identity.title(side))
            if partial {
                Text("· stopped before it finished")
            }
        }
    }
}
