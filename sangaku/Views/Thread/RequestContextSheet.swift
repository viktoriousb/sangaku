import SwiftData
import SwiftUI

/// View context: exactly what a model saw for one request, what was left out, the tokens and the cost, and for a
/// structured request the output exactly as it arrived.
struct RequestContextSheet: View {
    let record: RequestRecord

    @Environment(\.dismiss) private var dismiss
    @Environment(\.threadManager) private var threads
    @State private var showingRawOutput = false

    /// Long contexts are shown up to this many characters; Copy always copies everything.
    private static let displayLimit = 200_000

    var body: some View {
        let parameters = JSONColumn.decode(RequestParameters.self, from: record.parametersJSON)
        let resolution = (threads?.catalog ?? .standard).resolve(record.modelID)
        VStack(alignment: .leading, spacing: 14) {
            Text("What the model saw").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                row("Provider", record.providerID)
                row("Model", resolution.displayName + (resolution.info == nil ? "" : " (\(record.modelID))"))
                if let answered = record.answeredModelID, answered != record.modelID {
                    row("Answered by", answered)
                }
                row("Prompt", record.promptVersion)
                if let parameters {
                    row("Thinking", "\(parameters.effort.title) effort, \(parameters.thinking ?? "default")")
                    row("Output limit", "\(parameters.maxOutputTokens) tokens")
                    if let format = parameters.outputFormat {
                        row("Output format", "\(format), as a JSON schema")
                    }
                }
                if let state = record.parseState {
                    row("Output read", Self.describe(state))
                }
                row("Sent", record.createdAt.formatted(date: .abbreviated, time: .standard))
                row("Ended", ending)
            }
            .font(.callout)

            GroupBox("Tokens") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    tokenRow("Input at the full rate", record.inputTokens)
                    tokenRow("Written to the cache", record.cacheWriteTokens)
                    tokenRow("Read from the cache", record.cachedInputTokens)
                    tokenRow("Output, thinking included", record.outputTokens)
                    tokenRow("Estimated before sending", record.estimatedInputTokens)
                    GridRow {
                        Text("Cost").foregroundStyle(.secondary)
                        Text(costText)
                    }
                }
                .font(.callout.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Left out to fit the window") {
                VStack(alignment: .leading, spacing: 4) {
                    if !record.droppedItemsAreReadable {
                        Label("The list of what was left out could not be read.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(ColorToken.refuted.color)
                    } else if record.droppedItems.isEmpty {
                        Text("Nothing was left out.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(record.droppedItems.enumerated()), id: \.offset) { _, item in
                            Text("\(item.kind): \(item.title) · ≈ \(UsageFormat.tokens(item.tokens)) tokens")
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            let shown = showingRawOutput ? record.rawOutput ?? "" : record.contextText
            HStack {
                if record.rawOutput != nil {
                    Picker("Show", selection: $showingRawOutput) {
                        Text("Text Sent").tag(false)
                        Text("Raw Output").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("The text sent to the model, or the model's output exactly as it arrived")
                } else {
                    Text("Text sent").font(.subheadline.weight(.semibold))
                }
                if shown.count > Self.displayLimit {
                    Text("Showing the first \(Self.displayLimit) of \(shown.count) characters; Copy copies everything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(String(shown.prefix(Self.displayLimit)))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 240)
            .background(Color(nsColor: .textBackgroundColor))
            .border(.separator)

            HStack {
                Button("Copy Text Sent") {
                    Pasteboard.copy(record.contextText)
                }
                if let raw = record.rawOutput {
                    Button("Copy Raw Output") {
                        Pasteboard.copy(raw)
                    }
                    .help("The model's output exactly as it arrived")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 760)
    }

    static func describe(_ state: ParseState) -> String {
        switch state {
        case .clean: "Read whole, as the format asks"
        case .partial: "Read in part: the request ended early; the raw output keeps the rest"
        case .unstructured: "Could not be read as structure; shown as written"
        }
    }

    private var ending: String {
        if let error = record.errorMessage { return error }
        if record.contextText.isEmpty && record.finishedAt != nil { return "Never sent: stopped before its turn came" }
        switch record.stopReason {
        case "end_turn": return "Finished"
        case "max_tokens": return "Cut off at the output limit"
        case "refusal": return "Declined by the provider" + (record.stopCategory.map { " (\($0))" } ?? "")
        case let reason?:
            switch LocalStopReason(rawValue: reason) {
            case .stopped: return "Stopped"
            case .appQuit: return "Stopped when sangaku quit"
            case .orphaned: return "sangaku closed before the reply finished; text that arrived was not saved"
            case nil: return "Ended early (\(reason)); the reply may be incomplete"
            }
        case nil: return record.finishedAt == nil ? "Still running" : "Unknown"
        }
    }

    private var costText: String {
        guard let cost = record.estimatedCost else {
            return (threads?.catalog ?? .standard).resolve(record.modelID).info == nil
                ? "Price unknown for \(record.modelID)" : "Not recorded: the request ended without usage"
        }
        let qualifier = record.usageReported ? "≈" : "at least"
        return "\(qualifier) \(UsageFormat.cost(cost)) at prices as of \(ModelCatalog.pricesAsOf)"
            + (record.usageReported ? "" : " (the provider did not report final usage)")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func tokenRow(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text("\(value)")
        }
    }
}

#if DEBUG
#Preview("View context", traits: .fixture) {
    @Previewable @Query(filter: #Predicate<RequestRecord> { $0.usageReported }) var records: [RequestRecord]
    if let record = records.first {
        RequestContextSheet(record: record)
    }
}
#endif
