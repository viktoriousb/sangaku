import SwiftData
import SwiftUI

/// One step in Review: who wrote it, its text (provisional until a person's ✓ counts, invariant 3), what it
/// establishes, the model's confidence (shown, never used, invariant 10), its standing, open objections, comments
/// and history. The current step also shows the review actions.
struct ReviewStepRow: View {
    let step: StepReview
    let authors: AuthorDirectory
    let isCurrent: Bool
    /// The step list has the keyboard, so the keys act on this step if it is current.
    var isActive = false
    /// "Lem 3" when Review was opened for that statement's source steps and this is one of them.
    var highlightLabel: String?
    var notice: ReviewRowNotice?
    var focus: FocusState<ReviewFocus?>.Binding

    @Environment(\.reviewActions) private var actions
    @Environment(\.reviewManager) private var reviews

    var body: some View {
        let standing = step.standing
        let marks = ProvenanceBar.segments(step.provenance.versions, authors: authors)
        VStack(alignment: .leading, spacing: 10) {
            if let notice {
                if notice.isError {
                    Label(notice.message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(ColorToken.refuted.color)
                } else {
                    HStack(spacing: 8) {
                        Text(notice.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if notice.canUndo {
                            Button("Undo") { actions?(.undo(step)) }
                                .help("Undo this mark (⌘Z)")
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 2) {
                    Text("\(step.index)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    // The margin's authors without colour; the provenance line says the same to VoiceOver.
                    Text(marks.map(\.text).joined(separator: "·"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                .frame(minWidth: 22)
                VStack(alignment: .leading, spacing: 6) {
                    MathText(step.text)
                        .foregroundStyle(StepReviewStyle.row(standing).ink.color)
                        .textSelection(.enabled)
                    if !step.establishes.isEmpty {
                        Text("Establishes: \(step.establishes)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(Array(ReviewWording.chips(for: step, authors: authors).enumerated()), id: \.offset) { _, style in
                            StatusBadge(style: style)
                        }
                        ConfidenceChip(confidence: step.confidence)
                        if let highlightLabel {
                            Text("In \(highlightLabel)")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay { Capsule().strokeBorder(Color.accentColor) }
                        }
                    }
                    Text(ReviewWording.provenanceLine(step, authors: authors))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !isCurrent, let draft = reviews?.commentDraft(for: step.id), !draft.text.isEmpty {
                        Label("Unsent comment", systemImage: "text.bubble")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { ProvenanceBar(marks: marks).padding(.vertical, 2) }
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded { actions?(.focus(step.id)) })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
            .accessibilityAction(named: "Make Current") { actions?(.focus(step.id)) }

            ForEach(standing.openObjections) { objection in
                ObjectionCard(step: step, objection: objection, authors: authors)
            }
            ForEach(standing.dismissedObjections) { objection in
                Text(ReviewWording.dismissalLine(objection, authors: authors))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(standing.withdrawnObjections) { objection in
                Text(ReviewWording.withdrawalLine(objection, authors: authors))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isCurrent {
                StepActionsBar(step: step, myCheck: standing.checks.first { $0.reviewerID == authors.meID })
            }
            if isCurrent || !step.comments.isEmpty {
                CommentThread(step: step, authors: authors, showsComposer: isCurrent, focus: focus)
            }
            StepHistoryView(step: step, authors: authors)
        }
        .padding(14)
        .statusFrame(StepReviewStyle.row(standing))
        .overlay {
            // Solid while the step list has the keyboard, faint otherwise: where J, K and 1 2 3 will act.
            if isCurrent {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(isActive ? 1 : 0.35), lineWidth: 2)
            }
        }
        .contextMenu {
            ForEach(ReviewVerdict.allCases, id: \.self) { verdict in
                Button("Mark \(verdict.title) \(verdict.glyph)") { actions?(.mark(step, verdict)) }
            }
            Button("Comment on Step") { actions?(.comment(step)) }
            Button("Revise Step…") { actions?(.revise(step)) }
            Divider()
            Button("Copy LaTeX Source") { Pasteboard.copy(step.text) }
        }
    }
}

/// ✓ Correct, ✗ Wrong, ? Unclear, Comment, Revise and, when I have a counted ✓, Withdraw.
private struct StepActionsBar: View {
    let step: StepReview
    let myCheck: ReviewFact?

    @Environment(\.reviewActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                Text("Your review")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ReviewVerdict.allCases, id: \.self) { verdict in
                    Button("\(verdict.glyph) \(verdict.title)") { actions?(.mark(step, verdict)) }
                        .accessibilityLabel("Mark \(verdict.title.lowercased())")
                }
                Button("Comment") { actions?(.comment(step)) }
                Button("Revise…") { actions?(.revise(step)) }
                if let myCheck {
                    Button("Withdraw My ✓") { actions?(.withdraw(step, myCheck)) }
                        .accessibilityLabel("Withdraw my check")
                }
            }
            Text(ReviewKeys.legend)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// An open ✗ or ?: who raised it and when, and Dismiss. It blocks the step's check (invariant 11).
private struct ObjectionCard: View {
    let step: StepReview
    let objection: ReviewFact
    let authors: AuthorDirectory

    @Environment(\.reviewActions) private var actions

    /// Raised by the person using the app, who may withdraw it.
    private var isMine: Bool { objection.reviewerID != nil && objection.reviewerID == authors.meID }

    var body: some View {
        let style = StepReviewStyle.objection(objection.verdict, by: authors.initials(ofPerson: objection.reviewerID))
        VStack(alignment: .leading, spacing: 6) {
            Text(ReviewWording.objectionLine(objection, authors: authors))
                .font(.callout.weight(.medium))
                .foregroundStyle(style.ink.color)
            if !objection.note.isEmpty {
                Text(objection.note).font(.callout)
            }
            Text(isMine ? "Blocks the step's check until it is revised, you withdraw it, or a person dismisses it with a reason."
                        : "Blocks the step's check until it is revised or a person dismisses it with a reason.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if isMine {
                    Button("Withdraw") { actions?(.withdraw(step, objection)) }
                        .accessibilityLabel("Withdraw my objection")
                }
                Button("Dismiss…") { actions?(.dismiss(step, objection)) }
                    .accessibilityLabel("Dismiss this objection with a reason")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statusFrame(style, cornerRadius: 8)
    }
}

#if DEBUG
/// The example's attempt A as Review sees it, for previews.
struct ReviewPreviewData<Content: View>: View {
    @ViewBuilder let content: (AttemptReviewState, AuthorDirectory) -> Content

    @Query private var problems: [Problem]
    @Query private var people: [Person]
    @Query private var attempts: [ProofAttempt]
    @Environment(\.reviewManager) private var reviews

    var body: some View {
        if let reviews, let problem = problems.first,
           let attempt = attempts.first(where: { ($0.steps ?? []).count == 6 }) {
            content(reviews.state(of: attempt), AuthorDirectory(problem: problem, people: people, catalog: .standard))
        }
    }
}

/// Rows with the focus state they take.
private struct ReviewRowsPreview: View {
    let current: Int

    @FocusState private var focus: ReviewFocus?

    var body: some View {
        ReviewPreviewData { state, authors in
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.steps) { step in
                    ReviewStepRow(step: step, authors: authors, isCurrent: step.index == current, isActive: true,
                                  focus: $focus)
                }
            }
            .padding()
        }
    }
}

#Preview("Review rows", traits: .fixture, .fixedLayout(width: 640, height: 1800)) {
    ScrollView { ReviewRowsPreview(current: 5) }
}

#Preview("Review rows, dark", traits: .fixture, .fixedLayout(width: 640, height: 1800)) {
    ScrollView { ReviewRowsPreview(current: 6) }
        .preferredColorScheme(.dark)
}
#endif
