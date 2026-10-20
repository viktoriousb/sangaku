import SwiftData
import SwiftUI

/// A referee's message: a verdict chip per attempt, the summary and each rationale, and the actions later
/// milestones enable. A verdict is a model's check, so the message sits in the provisional frame.
struct RefereeMessageRow: View {
    let message: Message
    let stream: MessageStream?
    /// The fan-out it judged, when it is on this branch.
    let fanOut: FanOut?
    let authors: AuthorDirectory
    let onViewContext: (RequestRecord) -> Void
    let onStop: () -> Void

    var body: some View {
        let outcome = message.outcome(isStreaming: stream != nil)
        let attempts = (fanOut?.attempts ?? []).compactMap(\.message).sorted { $0.createdAt < $1.createdAt }
        let letters = attempts.compactMap { attempt -> String? in
            guard case .model(let slot) = attempt.author else { return nil }
            return authors.letter(of: slot)
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let attribution = authors.attribution(of: message) { ModelByline(attribution: attribution) }
                if !letters.isEmpty {
                    Text("read \(Prose.list(letters)) after \(letters.count == 1 ? "it" : "they") ended")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-2)
                }
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                if stream != nil {
                    Button("Stop", systemImage: "stop.circle", action: onStop)
                        .buttonStyle(.borderless)
                        .help("Stop the referee")
                }
                StatusBadge(style: StatusStyle.style(for: .proposed), compact: true)
            }
            if let stream {
                StreamPhaseLabel(phase: stream.phase, writing: "Writing verdicts…")
            } else {
                RefereeVerdicts(message: message, attempts: attempts, verdicts: verdicts, authors: authors)
            }
            if stream == nil, outcome != .complete {
                OutcomeLine(outcome: outcome, stopReason: message.request?.stopReason)
            }
            if let record = message.request, stream == nil {
                RequestFooter(record: record) { onViewContext(record) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MessageFrame(isModel: true))
        .contextMenu {
            Button("Copy LaTeX Source") {
                Pasteboard.copy(stream?.fullText ?? message.bodyLaTeX)
            }
            if let record = message.request {
                Button("View Context…") { onViewContext(record) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Referee message from \(authors.name(of: message.author))")
    }

    /// The verdicts this message gave.
    private var verdicts: [RefereeVerdict] {
        (fanOut?.verdicts ?? []).filter { $0.messageID == message.stableID }
    }
}

private struct RefereeVerdicts: View {
    let message: Message
    let attempts: [Message]
    let verdicts: [RefereeVerdict]
    let authors: AuthorDirectory

    var body: some View {
        let ink = StatusStyle.style(for: .proposed).ink.color
        // Unreadable when it could not be parsed, or when it ended but was never read (sangaku closed first).
        let record = message.request
        let unreadable = record?.parseState == .unstructured
            || (record != nil && record?.parseState == nil && record?.finishedAt != nil && verdicts.isEmpty)
        VStack(alignment: .leading, spacing: 10) {
            if unreadable {
                Label("The verdicts could not be read, so none were recorded. The referee's answer is shown as written.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(ColorToken.refuted.color)
                RawOutputText(text: message.bodyLaTeX)
            } else {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(attempts, id: \.stableID) { attempt in
                        let verdict = verdicts.first { $0.attempt?.message?.stableID == attempt.stableID }
                        VerdictChip(letter: letter(of: attempt), outcome: verdict?.outcome,
                                    gapSteps: verdict?.gapStepIndices ?? [], partial: verdict?.sawPartialAttempt ?? false)
                    }
                }
                if !message.bodyLaTeX.isEmpty {
                    MathText(message.bodyLaTeX)
                        .foregroundStyle(ink)
                        .textSelection(.enabled)
                }
                ForEach(attempts, id: \.stableID) { attempt in
                    if let verdict = verdicts.first(where: { $0.attempt?.message?.stableID == attempt.stableID }),
                       !verdict.rationale.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("On Model \(letter(of: attempt))'s attempt")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            MathText(verdict.rationale)
                                .foregroundStyle(ink)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            RefereeActions(attempts: attempts)
        }
    }

    private func letter(of attempt: Message) -> String {
        guard case .model(let slot) = attempt.author else { return "?" }
        return authors.letter(of: slot)
    }
}

/// What a person can do with a referee's verdicts. Promoting and reviewing work now; adopting arrives with a later
/// milestone and says which, in words a keyboard user sees too (a disabled button takes no focus, so its tooltip
/// alone would be missed).
private struct RefereeActions: View {
    let attempts: [Message]

    @Environment(\.promoteSteps) private var promote
    @Environment(\.openReview) private var openReview
    @Environment(\.openCompare) private var openCompare

    var body: some View {
        // Only attempts that were read as steps can be promoted from or reviewed.
        let promotable = attempts.compactMap(\.proofAttempt).filter { !($0.steps ?? []).isEmpty }.map(\.stableID)
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 8, lineSpacing: 6) {
                Button("Adopt as Main Line") {}
                    .disabled(true)
                    .help("Adopting an attempt arrives with Milestone 7 (Branches)")
                Button("Promote Step to Lemma…") { promote?(PromotionTarget(attemptIDs: promotable)) }
                    .disabled(promote == nil || promotable.isEmpty)
                    .help(promotable.isEmpty ? "No attempt was read as steps" : "Choose steps of an attempt and make them a lemma")
                Button("Review Step by Step") { openReview?(ReviewTarget(attemptIDs: promotable)) }
                    .disabled(openReview == nil || promotable.isEmpty)
                    .help(promotable.isEmpty ? "No attempt was read as steps" : "Open these attempts in Review")
                Button("Compare Attempts") { openCompare?(CompareTarget(attemptIDs: promotable)) }
                    .disabled(openCompare == nil || promotable.count < 2)
                    .help(promotable.count < 2 ? "Comparing needs two attempts read as steps" : "Set these attempts side by side, step by step")
            }
            Text("Adopting an attempt as the main line arrives with Milestone 7.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
#Preview("Referee message", traits: .fixture, .fixedLayout(width: 760, height: 520)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query var people: [Person]
    @Previewable @Query var fanOuts: [FanOut]
    @Previewable @Query(filter: #Predicate<Message> { $0.kindRaw == "referee" }) var referees: [Message]
    if let problem = problems.first, let referee = referees.first {
        let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
        VStack(spacing: 12) {
            RefereeMessageRow(message: referee, stream: nil, fanOut: fanOuts.first, authors: authors,
                              onViewContext: { _ in }, onStop: {})
            RefereeMessageRow(message: referee, stream: MessageStream(), fanOut: fanOuts.first, authors: authors,
                              onViewContext: { _ in }, onStop: {})
        }
        .padding()
    }
}
#endif
