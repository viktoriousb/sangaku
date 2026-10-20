import SwiftData
import SwiftUI

/// One prover's attempt in a fan-out: its numbered steps, each with what it establishes and the model's confidence;
/// how it ended; and what it cost. Unchecked math, so it sits in the provisional frame (invariant 3).
struct AttemptCard: View {
    let message: Message
    let stream: MessageStream?
    let authors: AuthorDirectory
    /// Runs of steps matching the other attempt, judged equivalent on the current text: shown collapsed.
    var matches: MatchedRuns?
    let onViewContext: (RequestRecord) -> Void
    let onStop: () -> Void

    var body: some View {
        let attribution = authors.attribution(of: message)
        let outcome = message.outcome(isStreaming: stream != nil)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let attribution { ModelByline(attribution: attribution) }
                Spacer(minLength: 4)
                if stream != nil {
                    Button("Stop", systemImage: "stop.circle", action: onStop)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(stream?.phase == .queued ? "Take this attempt out of the queue" : "Stop this attempt; what has arrived is kept, and the referee still sees it, marked partial")
                }
                StatusBadge(style: StatusStyle.style(for: .proposed), compact: true)
            }
            if let stream {
                LiveAttemptBody(stream: stream)
            } else {
                FinishedAttemptBody(message: message, authors: authors, matches: matches)
            }
            if stream == nil, outcome != .complete {
                OutcomeLine(outcome: outcome, stopReason: message.request?.stopReason,
                            neverSent: message.request.map { $0.contextText.isEmpty } ?? false)
            }
            if let record = message.request, stream == nil {
                RequestFooter(record: record) { onViewContext(record) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .statusFrame(StatusStyle.style(for: .proposed))
        .contextMenu {
            Button("Copy LaTeX Source") {
                Pasteboard.copy(Self.source(of: message, stream: stream))
            }
            if let record = message.request {
                Button("View Context…") { onViewContext(record) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attempt by \(authors.name(of: message.author))")
    }

    /// The attempt as text: its overview and numbered steps, or the raw output when it was not read as steps.
    static func source(of message: Message, stream: MessageStream?) -> String {
        if let stream { return stream.fullText }
        let steps = message.proofAttempt?.sortedSteps ?? []
        guard !steps.isEmpty else { return message.bodyLaTeX }
        let lines = steps.map { "Step \($0.index) (establishes: \($0.establishes); confidence: \($0.confidence.rawValue)): \($0.textLaTeX)" }
        return ([message.bodyLaTeX].filter { !$0.isEmpty } + lines).joined(separator: "\n\n")
    }
}

/// An attempt that has ended: overview and steps, or its text as written when it could not be read as steps.
private struct FinishedAttemptBody: View {
    let message: Message
    let authors: AuthorDirectory
    var matches: MatchedRuns?

    var body: some View {
        let attempt = message.proofAttempt
        let steps = attempt?.sortedSteps ?? []
        let state = message.request?.parseState
        let standing = attempt?.standingVerdict
        let gaps = standing?.outcome == .gap ? Set(standing?.gapStepIndices ?? []) : []
        let referee = (attempt?.verdicts ?? []).max { $0.createdAt < $1.createdAt }?.refereeSlotID
            .map { authors.letter(of: ModelSlotID($0)) } ?? "the referee"
        let unreadable = state == .unstructured || (steps.isEmpty && state == nil)
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.summary(steps: steps, unreadable: unreadable, empty: message.bodyLaTeX.isEmpty))
                .font(.caption)
                .foregroundStyle(.secondary)
            if unreadable {
                RawOutputText(text: message.bodyLaTeX)
            } else {
                if !message.bodyLaTeX.isEmpty {
                    MathText(message.bodyLaTeX)
                        .foregroundStyle(StatusStyle.style(for: .proposed).ink.color)
                        .textSelection(.enabled)
                }
                let runs = matches?.runs ?? []
                ForEach(steps) { step in
                    if let run = runs.first(where: { $0.contains(step.index) }) {
                        if step.index == run.lowerBound {
                            MatchedSteps(title: CompareWording.matchRun(run, other: matches?.other ?? "the other attempt"),
                                         steps: steps.filter { run.contains($0.index) }, attempt: attempt,
                                         gaps: gaps, referee: referee)
                        }
                    } else {
                        row(step, attempt: attempt, gaps: gaps, referee: referee)
                    }
                }
                if state == .partial {
                    Label("Only the steps complete when it stopped are shown; everything that arrived is under Raw Output in View Context.",
                          systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ step: Step, attempt: ProofAttempt?, gaps: Set<Int>, referee: String) -> some View {
        StepRow.forAttempt(step, attempt: attempt, gaps: gaps, referee: referee)
    }

    static func summary(steps: [Step], unreadable: Bool, empty: Bool) -> String {
        if unreadable { return empty ? "No text arrived" : "Could not be read as steps; shown as written" }
        let delicate = steps.filter { $0.confidence == .delicate }.count
        return "\(Prose.count(steps.count, "step")) · \(delicate) delicate"
    }
}

/// A run of steps matching the other attempt, collapsed to one line ("Steps 1–4 match A's") that opens to show them.
private struct MatchedSteps: View {
    let title: String
    let steps: [Step]
    let attempt: ProofAttempt?
    let gaps: Set<Int>
    let referee: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(steps) { StepRow.forAttempt($0, attempt: attempt, gaps: gaps, referee: referee) }
            }
            .padding(.top, 4)
        } label: {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

extension StepRow {
    /// A step of a finished attempt, which can be promoted and reviewed.
    static func forAttempt(_ step: Step, attempt: ProofAttempt?, gaps: Set<Int>, referee: String) -> StepRow {
        StepRow(index: step.index, text: step.textLaTeX, establishes: step.establishes, confidence: step.confidence,
                gapListedBy: gaps.contains(step.index) ? referee : nil,
                promotion: attempt.map { PromotionTarget(attemptIDs: [$0.stableID], stepID: step.stableID) },
                review: attempt.map { ReviewTarget(attemptIDs: [$0.stableID], stepID: step.stableID) })
    }
}

/// An attempt while it streams: the steps complete so far, read off the main actor, and what the model is doing.
/// Only this view observes the stream.
private struct LiveAttemptBody: View {
    let stream: MessageStream

    @State private var steps: [ParsedStep] = []

    var body: some View {
        let text = stream.text
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { offset, step in
                StepRow(index: offset + 1, text: step.text, establishes: step.establishes, confidence: step.confidence)
            }
            // Output that is not the structured form (a refusal, say) is shown as it arrives.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("{") {
                RawOutputText(text: String(text.suffix(600)))
            }
            StreamPhaseLabel(phase: stream.phase, writing: "Writing step \(steps.count + 1)…")
        }
        .task(id: text.utf8.count) {
            let parsed = await OutputParsing.progress(text)
            // A newer text has replaced this one: its own read sets the steps.
            guard !Task.isCancelled else { return }
            steps = parsed
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

#if DEBUG
#Preview("Attempt cards", traits: .fixture, .fixedLayout(width: 640, height: 1100)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query var people: [Person]
    @Previewable @Query(filter: #Predicate<Message> { $0.kindRaw == "attempt" }, sort: \Message.createdAt)
    var attempts: [Message]
    if let problem = problems.first, attempts.count >= 2 {
        let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
        let writing = MessageStream()
        let _ = writing.apply(.text(String(DemoTransport.soundAttempt.prefix(500))))
        ScrollView {
            EqualColumnsLayout {
                AttemptCard(message: attempts[0], stream: nil, authors: authors, onViewContext: { _ in }, onStop: {})
                AttemptCard(message: attempts[1], stream: nil, authors: authors, onViewContext: { _ in }, onStop: {})
                AttemptCard(message: attempts[0], stream: writing, authors: authors, onViewContext: { _ in }, onStop: {})
                AttemptCard(message: attempts[1], stream: MessageStream(phase: .queued), authors: authors,
                            onViewContext: { _ in }, onStop: {})
            }
            .padding()
        }
    }
}
#endif
