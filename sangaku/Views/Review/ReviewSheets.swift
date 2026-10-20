import SwiftUI

/// A new version of a step, written by the person using the app. The version it was opened on is kept, so saving
/// after someone else revised the step is refused rather than overwriting what they wrote.
struct ReviseSheet: View {
    let step: StepReview
    let authors: AuthorDirectory

    @Environment(\.reviewManager) private var reviews
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var establishes = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Revise Step \(step.index)").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Current version").font(.caption).foregroundStyle(.secondary)
                MathText(step.text).foregroundStyle(.secondary)
            }
            Form {
                LabeledContent("Text (LaTeX)") {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                }
                TextField("Establishes", text: $establishes)
                LabeledContent("Preview") {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("—").foregroundStyle(.tertiary)
                    } else {
                        MathText(text)
                    }
                }
            }
            Text(ReviewWording.revisionConsequences(step, establishes: establishes, authors: authors))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ColorToken.refuted.color)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Revision") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            text = step.text
            establishes = step.establishes
        }
    }

    private func save() {
        guard let reviews else { return }
        guard let revision = step.standing.currentRevisionID else {
            error = ReviewError.noRevision.message
            return
        }
        do {
            try reviews.revise(step.id, from: revision, text: text, establishes: establishes)
            VoiceOver.announce("Step \(step.index) revised")
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}

/// Closes an open ✗ or ? with a reason. Marking the version ✓ at the same time is offered and off by default, so
/// closing an objection is never a check by itself.
struct DismissSheet: View {
    let step: StepReview
    let objection: ReviewFact
    let authors: AuthorDirectory

    @Environment(\.reviewManager) private var reviews
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var alsoCheck = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dismiss the Objection on Step \(step.index)").font(.headline)
            Text(ReviewWording.objectionLine(objection, authors: authors))
                .foregroundStyle(.secondary)
            if !objection.note.isEmpty {
                Text(objection.note)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Reason (required)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $reason)
                    .frame(minHeight: 70)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator) }
                    .accessibilityLabel("Reason for dismissing")
            }
            Toggle("Also mark this version ✓", isOn: $alsoCheck)
            if alsoCheck, step.standing.openObjections.count > 1 {
                Text("Another objection stays open, so the ✓ will not count until it is closed too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ColorToken.refuted.color)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(alsoCheck ? "Dismiss and Mark ✓" : "Dismiss") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        guard let reviews else { return }
        do {
            if alsoCheck {
                guard let revision = step.standing.currentRevisionID else {
                    error = ReviewError.noRevision.message
                    return
                }
                try reviews.resolve(objection.id, reason: reason, alsoCheck: true, revision: revision)
            } else {
                try reviews.dismiss(objection.id, reason: reason)
            }
            VoiceOver.announce("Objection on step \(step.index) dismissed")
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}

#if DEBUG
#Preview("Revise", traits: .fixture) {
    ReviewPreviewData { state, authors in
        if let step = state.steps.first(where: { $0.index == 3 }) {
            ReviseSheet(step: step, authors: authors)
        }
    }
}

#Preview("Dismiss", traits: .fixture) {
    ReviewPreviewData { state, authors in
        if let step = state.steps.first(where: { $0.index == 5 }), let objection = step.standing.openObjections.first {
            DismissSheet(step: step, objection: objection, authors: authors)
        }
    }
}
#endif
