import SwiftUI

// The parts message rows, attempt cards and referee messages share.

/// "A · Model A · Prover · Claude Opus 5.5": the slot's badge, letter and role, and the model.
struct ModelByline: View {
    let attribution: AuthorDirectory.Attribution

    var body: some View {
        AuthorBadge(text: attribution.letter, colorToken: attribution.colorToken)
        Text("Model \(attribution.letter)" + (attribution.role.map { " · \($0.rawValue.capitalized)" } ?? ""))
            .font(.callout.weight(.semibold))
            .lineLimit(1)
        Text(attribution.modelName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutPriority(-1)
    }
}

/// Model messages sit in the provisional frame; people's messages in a plain one.
struct MessageFrame: ViewModifier {
    let isModel: Bool

    func body(content: Content) -> some View {
        if isModel {
            content.statusFrame(StatusStyle.style(for: .proposed))
        } else {
            content.background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
        }
    }
}

/// What a live request is doing before it writes: waiting for its turn, for the model, or thinking.
struct StreamPhaseLabel: View {
    let phase: MessageStream.Phase
    var writing: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch phase {
            case .queued:
                Label("Waits for its turn; it will see the attempts before it.", systemImage: "clock")
            case .connecting:
                Label("Waiting for the model…", systemImage: "hourglass")
            case .thinking:
                Label("Thinking…", systemImage: "brain")
                    .symbolEffect(.pulse, isActive: !reduceMotion)
            case .writing:
                if let writing { Label(writing, systemImage: "pencil") }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// How a request ended, as a glyph and words (never colour alone).
struct OutcomeLine: View {
    let outcome: MessageOutcome
    let stopReason: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch outcome {
            case .interrupted:
                Label(interruptedText, systemImage: "stop.circle")
            case .declined(let category):
                Label("Declined by the provider" + (category.map { " (\($0))" } ?? "") + ". No other model answered.",
                      systemImage: "hand.raised")
            case .failed(let kind, let message):
                Label(message, systemImage: "exclamationmark.triangle")
                if ProviderError.kindConcernsKey(kind) {
                    SettingsLink { Text("Open Settings…") }
                        .buttonStyle(.link)
                }
            case .cutOff:
                Label("Cut off at the output limit; the reply is incomplete.", systemImage: "scissors")
            case .endedEarly(let reason):
                Label("Ended early (\(reason)); the reply may be incomplete.", systemImage: "exclamationmark.circle")
            case .streaming, .complete:
                EmptyView()
            }
        }
        .font(.callout)
        .foregroundStyle(ColorToken.refuted.color)
    }

    var neverSent = false

    private var interruptedText: String {
        if neverSent { return "Stopped before its turn came; nothing was sent." }
        return switch stopReason.flatMap(LocalStopReason.init(rawValue:)) {
        case .appQuit: "Stopped when sangaku quit; the partial reply is kept."
        case .orphaned: "sangaku closed before this reply finished; text that arrived was not saved."
        case .stopped, nil: "Stopped; the partial reply is kept."
        }
    }
}

/// Tokens, cost and View context.
struct RequestFooter: View {
    let record: RequestRecord
    let onViewContext: () -> Void

    @Environment(\.threadManager) private var threads

    var body: some View {
        HStack(spacing: 10) {
            Text(summary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("View Context", systemImage: "doc.text.magnifyingglass", action: onViewContext)
                .buttonStyle(.borderless)
                .font(.caption)
                .help("The exact text sent, what was left out, tokens and cost")
        }
    }

    private var summary: String {
        let usage = record.usage
        if record.contextText.isEmpty && record.finishedAt != nil { return "Not sent" }
        if !record.usageReported && usage.promptTotal == 0 && usage.output == 0 {
            return "No usage reported"
        }
        var parts = ["\(UsageFormat.tokens(usage.promptTotal)) in"]
        if record.cachedInputTokens > 0 { parts.append("\(UsageFormat.tokens(record.cachedInputTokens)) cached") }
        parts.append(record.usageReported ? "\(UsageFormat.tokens(record.outputTokens)) out" : "output unknown")
        if let cost = record.estimatedCost {
            parts.append((record.usageReported ? "≈ " : "≥ ") + UsageFormat.cost(cost))
        } else if (threads?.catalog ?? .standard).resolve(record.modelID).info == nil {
            parts.append("price unknown")
        } else {
            parts.append("cost not recorded")
        }
        let dropped = record.droppedItems.count
        if dropped > 0 { parts.append("\(dropped) left out") }
        return parts.joined(separator: " · ")
    }
}

/// Model output that could not be read as structure, shown exactly as written: never typeset as mathematics it may
/// not be, since a doubled backslash would read as a line break.
struct RawOutputText: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
