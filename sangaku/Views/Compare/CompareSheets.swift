import SwiftData
import SwiftUI

/// Aligning two attempts: which model aligns them, what it costs and what its context leaves out, before anything
/// is sent. While blind, every name and reason comes through `CompareIdentity`.
struct AlignSheet: View {
    let problem: Problem
    let branch: Branch
    let pair: ComparedPair
    let choice: AlignerChoice
    let identity: CompareIdentity
    let rerun: Bool

    @Environment(\.threadManager) private var threads
    @Environment(\.dismiss) private var dismiss
    @State private var picked: UUID?
    @State private var error: String?

    var body: some View {
        let aligner = alignerID
        VStack(alignment: .leading, spacing: 14) {
            Text(rerun ? "Align Again" : "Align the Attempts").font(.headline)
            Text("A model pairs the steps of \(CompareWording.attempt(1)) and \(CompareWording.attempt(2)) by what they establish and judges each pair. It is shown the two attempts and nothing else of the thread, named only \(CompareWording.attempt(1)) and \(CompareWording.attempt(2)).")
                .fixedSize(horizontal: false, vertical: true)
            if rerun {
                Text("Your corrections are kept: they stand over the new rows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            switch choice {
            case .slot(let id):
                Text("Aligned by \(identity.aligners[id] ?? "the referee").").font(.callout)
            case .choose(let ids):
                Picker("Aligned by", selection: Binding(get: { aligner ?? ids[0] }, set: { picked = $0 })) {
                    ForEach(ids, id: \.self) { Text(identity.aligners[$0] ?? "A referee").tag($0) }
                }
                .fixedSize()
            case .none:
                Text(CompareError.noAligner.message)
                    .foregroundStyle(ColorToken.refuted.color)
            }
            if let aligner, let threads {
                switch threads.alignPlan(pair, aligner: aligner, problem: problem, branch: branch, effort: effort) {
                case .success(let recipient):
                    Text("Estimate: \(CompareWording.estimate(recipient, identity: identity)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let leftOut = CompareWording.leftOut(recipient) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Left out to fit the aligner's window:", systemImage: "scissors")
                            ForEach(Array(leftOut.enumerated()), id: \.offset) { _, item in
                                Text(identity.shielded(item, withheld: "An item that may name a model") ?? item)
                                    .padding(.leading, 20)
                            }
                        }
                        .font(.callout)
                    }
                case .failure(let blocker):
                    Label(identity.reason(blocker), systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(ColorToken.refuted.color)
                }
            }
            SheetErrorLine(error: error)
            SheetButtons(confirm: "Align", disabled: aligner == nil) { align() }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var alignerID: UUID? {
        switch choice {
        case .slot(let id): id
        case .choose(let ids): picked ?? ids.first
        case .none: nil
        }
    }

    /// The think-time chosen in this branch's composer.
    private var effort: ThinkingEffort {
        threads?.draft(for: branch.stableID).effort ?? .standard
    }

    private func align() {
        guard let threads, let aligner = alignerID else { return }
        do {
            try threads.align(pair, aligner: aligner, problem: problem, branch: branch, effort: effort)
            dismiss()
        } catch {
            self.error = identity.reason(error)
        }
    }
}

/// A question about a row, shown and editable before it is sent.
struct QuestionDraft: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var text: String
    var slotID: UUID
    var recipient: String
}

/// A question about one row, shown in full and editable before it is sent. The answer arrives in the thread.
struct QuestionSheet: View {
    let draft: QuestionDraft
    let problem: Problem
    let branch: Branch
    let attemptMessageIDs: [UUID]
    let onSent: @MainActor (String) -> Void

    @Environment(\.threadManager) private var threads
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.title).font(.headline)
            Text("This is sent as your message, with the problem, the notation and the thread so far. The answer arrives in the thread.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator) }
                .accessibilityLabel("Message to \(draft.recipient)")
            SheetErrorLine(error: error)
            SheetButtons(confirm: "Send", shortcut: KeyboardShortcut(.return, modifiers: .command),
                         disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { send() }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { text = draft.text }
    }

    private func send() {
        guard let threads else { return }
        do {
            try threads.ask(text, slot: draft.slotID, about: attemptMessageIDs, problem: problem, branch: branch,
                            effort: threads.draft(for: branch.stableID).effort)
            onSent(draft.recipient)
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}

#if DEBUG
#Preview("Align sheet, blind", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query var people: [Person]
    if let problem = problems.first, let branch = problem.sortedBranches.first,
       let a = problem.alignments?.first, let first = a.attemptAID, let second = a.attemptBID,
       let referee = problem.sortedModelSlots.first(where: { $0.role == .referee }) {
        let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
        AlignSheet(problem: problem, branch: branch, pair: ComparedPair(first: first, second: second),
                   choice: .slot(referee.stableID),
                   identity: .make(hidden: true, first: nil, second: nil, choice: .slot(referee.stableID), authors: authors),
                   rerun: true)
    }
}

#Preview("Question sheet", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first, let branch = problem.sortedBranches.first,
       let referee = problem.sortedModelSlots.first(where: { $0.role == .referee }) {
        QuestionSheet(draft: QuestionDraft(title: "Send this row to Model C",
                                           text: "In Compare, one row of the two attempts asks for your judgement.",
                                           slotID: referee.stableID, recipient: "Model C"),
                      problem: problem, branch: branch, attemptMessageIDs: []) { _ in }
    }
}
#endif
