import SwiftData
import SwiftUI

/// Makes a lemma or claim of a run of steps of one attempt. Everything stays a draft until Promote; the graph checks
/// it all before writing, so a refusal changes nothing.
struct PromoteSheet: View {
    let problem: Problem
    let target: PromotionTarget
    let onPromoted: (UUID) -> Void

    @Environment(\.statementGraph) private var graph
    @Environment(\.dismiss) private var dismiss
    @Query private var attempts: [ProofAttempt]
    @Query private var people: [Person]

    @State private var draft: PromotionDraft?
    @State private var error: String?

    init(problem: Problem, target: PromotionTarget, onPromoted: @escaping (UUID) -> Void) {
        self.problem = problem
        self.target = target
        self.onPromoted = onPromoted
        let ids = target.attemptIDs
        _attempts = Query(filter: #Predicate<ProofAttempt> { ids.contains($0.stableID) })
    }

    var body: some View {
        let state = graph?.state(for: problem, people: Set(people.map(\.stableID))) ?? .empty
        let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
        let ordered = attempts.sorted { ($0.message?.createdAt ?? .distantPast) < ($1.message?.createdAt ?? .distantPast) }
        VStack(alignment: .leading, spacing: 14) {
            Text("Promote Steps").font(.headline)
            if let draft, let attempt = ordered.first(where: { $0.stableID == draft.attemptID }) {
                form(draft: draft, attempt: attempt, attempts: ordered, state: state, authors: authors)
            } else {
                Text(StatementError.noSuchSteps.message).foregroundStyle(.secondary)
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
                Button("Promote") { promote() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { start(in: ordered, labels: state.nodes.map(\.label)) }
        // Should the attempts arrive after the sheet appears, start then.
        .onChange(of: attempts.count) { start(in: ordered, labels: state.nodes.map(\.label)) }
    }

    private func form(draft: PromotionDraft, attempt: ProofAttempt, attempts: [ProofAttempt],
                      state: StatementGraphState, authors: AuthorDirectory) -> some View {
        let steps = attempt.sortedSteps
        let texts = Self.texts(of: attempt)
        let labels = state.nodes.map(\.label)
        return Form {
            if attempts.count > 1 {
                Picker("Attempt", selection: Binding(
                    get: { draft.attemptID },
                    set: { id in
                        if let chosen = attempts.first(where: { $0.stableID == id }) { restart(on: chosen, labels: labels) }
                    })) {
                    ForEach(attempts, id: \.stableID) { attempt in
                        Text(authors.name(of: attempt.message?.author)).tag(attempt.stableID)
                    }
                }
            }
            Picker("From step", selection: Binding(
                get: { draft.run.lowerBound },
                set: { self.draft?.chooseRun(first: $0, last: draft.run.upperBound, texts: texts) })) {
                ForEach(steps, id: \.index) { Text("\($0.index). \($0.establishes)").tag($0.index) }
            }
            Picker("To step", selection: Binding(
                get: { draft.run.upperBound },
                set: { self.draft?.chooseRun(first: draft.run.lowerBound, last: $0, texts: texts) })) {
                ForEach(steps, id: \.index) { Text("\($0.index). \($0.establishes)").tag($0.index) }
            }
            Picker("Kind", selection: Binding(
                get: { draft.kind },
                set: { self.draft?.chooseKind($0, existingLabels: labels) })) {
                Text("Lemma").tag(StatementKind.lemma)
                Text("Claim").tag(StatementKind.claim)
            }
            .pickerStyle(.segmented)
            TextField("Label", text: Binding(get: { draft.label }, set: { self.draft?.editLabel($0) }))
            LabeledContent("Statement (LaTeX)") {
                TextEditor(text: Binding(get: { draft.statementLaTeX }, set: { self.draft?.editText($0) }))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 70)
            }
            LabeledContent("Preview") {
                if draft.statementLaTeX.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    MathText(draft.statementLaTeX)
                }
            }
            Text("A step is proof, not yet a statement: say what the steps establish. The lemma's status comes from these steps' checks and from what it uses.")
                .font(.caption)
                .foregroundStyle(.secondary)
            uses(draft: draft, state: state)
            if let pinned = state.pinned {
                Toggle("Used by \(pinned.label)", isOn: Binding(
                    get: { draft.usedByPinned }, set: { self.draft?.usedByPinned = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 620)
    }

    /// Every statement but the theorem, with its displayed status; using a refuted one caps the new lemma.
    private func uses(draft: PromotionDraft, state: StatementGraphState) -> some View {
        let candidates = state.nodes.filter { !$0.isPinned }
        return Section("Uses") {
            if candidates.isEmpty {
                Text("No other statements yet.").foregroundStyle(.secondary)
            }
            ForEach(candidates) { node in
                Toggle(isOn: Binding(
                    get: { draft.uses.contains(node.id) },
                    set: { on in
                        if on { self.draft?.uses.insert(node.id) } else { self.draft?.uses.remove(node.id) }
                    })) {
                    HStack(spacing: 6) {
                        StatusBadge(style: StatusStyle.style(for: node.derived.displayed), compact: true)
                        Text(node.label)
                        if node.derived.own == .refuted {
                            Text("refuted: caps this at sketched")
                                .font(.caption)
                                .foregroundStyle(ColorToken.refuted.color)
                        }
                    }
                }
            }
        }
    }

    private func start(in attempts: [ProofAttempt], labels: [String]) {
        guard draft == nil else { return }
        let attempt = attempts.first { attempt in (attempt.steps ?? []).contains { $0.stableID == target.stepID } }
            ?? attempts.first
        guard let attempt else { return }
        restart(on: attempt, labels: labels)
    }

    private func restart(on attempt: ProofAttempt, labels: [String]) {
        let steps = attempt.sortedSteps
        let index = steps.first { $0.stableID == target.stepID }?.index ?? steps.first?.index ?? 1
        draft = PromotionDraft(attemptID: attempt.stableID, first: index, last: index, existingLabels: labels,
                               texts: Self.texts(of: attempt))
        error = nil
    }

    /// The attempt's step texts by step number.
    private static func texts(of attempt: ProofAttempt) -> [Int: String] {
        Dictionary(attempt.sortedSteps.map { ($0.index, $0.textLaTeX) }, uniquingKeysWith: { first, _ in first })
    }

    private func promote() {
        guard let graph, let draft else { return }
        do {
            let statement = try graph.promote(draft, in: problem)
            AccessibilityNotification.Announcement("Promoted to \(statement.label)").post()
            onPromoted(statement.stableID)
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}

#if DEBUG
#Preview("Promote", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query(filter: #Predicate<Message> { $0.kindRaw == "attempt" }, sort: \Message.createdAt)
    var attempts: [Message]
    if let problem = problems.first, let attempt = attempts.first?.proofAttempt {
        PromoteSheet(problem: problem, target: PromotionTarget(attemptIDs: [attempt.stableID],
                                                               stepID: attempt.sortedSteps.dropFirst(2).first?.stableID)) { _ in }
    }
}
#endif
