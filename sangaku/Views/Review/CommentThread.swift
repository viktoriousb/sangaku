import SwiftUI

/// A step's comments, oldest first, each marked with the version it was written on when that is not the current
/// one. The current step also has a composer.
struct CommentThread: View {
    let step: StepReview
    let authors: AuthorDirectory
    let showsComposer: Bool
    var focus: FocusState<ReviewFocus?>.Binding

    @Environment(\.reviewManager) private var reviews

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(step.comments) { comment in
                let mark = authors.mark(of: comment.author)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AuthorBadge(text: mark.text, colorToken: mark.colorToken)
                    VStack(alignment: .leading, spacing: 2) {
                        Text([mark.name, ReviewTime.text(comment.createdAt), step.versionLabel(of: comment.revisionID).map { "on \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption.weight(.medium))
                        MathText(comment.body)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if showsComposer, let reviews {
                CommentComposer(step: step, draft: reviews.commentDraft(for: step.id), focus: focus)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}

/// Writes a comment on the current version. The draft is kept while the app runs, whichever step or view is shown.
/// ⌘↩ posts; Esc returns the keyboard to the step list.
private struct CommentComposer: View {
    let step: StepReview
    @Bindable var draft: CommentDraft
    var focus: FocusState<ReviewFocus?>.Binding

    @Environment(\.reviewManager) private var reviews
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft.text)
                .font(.callout)
                .frame(minHeight: 40, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text("Comment on this version…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .focused(focus, equals: .field(step.id))
                .onKeyPress(.escape) {
                    focus.wrappedValue = .list
                    return .handled
                }
                .accessibilityLabel("Comment on step \(step.index)")
            HStack {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(ColorToken.refuted.color)
                }
                Spacer()
                Button("Comment") { post() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func post() {
        guard let reviews else { return }
        guard let revision = step.standing.currentRevisionID else {
            error = ReviewError.noRevision.message
            return
        }
        do {
            try reviews.comment(draft.text, on: step.id, revision: revision)
            draft.text = ""
            error = nil
            AccessibilityNotification.Announcement("Comment added to step \(step.index)").post()
        } catch {
            self.error = error.message
        }
    }
}
