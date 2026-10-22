import SwiftData
import SwiftUI

/// Edits a statement's label and text, and whether it is a result from the literature. The theorem's text is the
/// problem statement, and a wording a Lean result or fidelity review was given for is fixed; both show why.
struct StatementEditor: View {
    let problem: Problem
    let node: StatementNode

    @Environment(\.statementGraph) private var graph
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var text = ""
    @State private var imported = false
    @State private var source = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(node.label)").font(.headline)
            Form {
                TextField("Label", text: $label, prompt: Text("Lem 5"))
                if let reason = lockReason {
                    LabeledContent("Statement") {
                        MathText(node.statementLaTeX)
                    }
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Statement (LaTeX)") {
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 90)
                    }
                    LabeledContent("Preview") {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("—").foregroundStyle(.tertiary)
                        } else {
                            MathText(text)
                        }
                    }
                }
                Section {
                    if let reason = importLockReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle("A result from the literature", isOn: $imported)
                        if imported {
                            TextField("Source", text: $source, prompt: Text("Authors, Theorem x.y"))
                            Text(StatementWording.importedCaption).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
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
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            label = node.label
            text = node.statementLaTeX
            imported = node.importedSource != nil
            source = node.importedSource ?? ""
        }
    }

    private var lockReason: String? {
        if node.isPinned { return StatementError.pinnedTextIsTheProblemStatement.message }
        if node.hasLeanCheck { return StatementError.textLockedByLeanCheck.message }
        return nil
    }

    /// Why this statement cannot be marked as imported, if it cannot.
    private var importLockReason: String? {
        if node.isPinned { return StatementError.pinnedCannotBeImported.message }
        if !node.sources.isEmpty { return StatementError.importedHasSteps.message }
        if node.importedSource == nil, !node.uses.isEmpty { return StatementError.importedUsesStatements.message }
        return nil
    }

    private func save() {
        guard let graph else { return }
        do {
            // Every check that can fail comes before the first change, so a refused save changes nothing.
            if importLockReason == nil, imported { _ = try StatementGraph.importedSource(source) }
            try graph.edit(node.id, label: label, statementLaTeX: lockReason == nil ? text : node.statementLaTeX,
                           in: problem)
            if importLockReason == nil {
                try graph.setImported(node.id, source: imported ? source : nil, in: problem)
            }
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}

#if DEBUG
#Preview("Edit statement", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Environment(\.statementGraph) var graph
    if let problem = problems.first, let graph,
       let node = graph.state(for: problem).nodes.first(where: { $0.label == "Lem 6" }) {
        StatementEditor(problem: problem, node: node)
    }
}

#Preview("Edit the theorem", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Environment(\.statementGraph) var graph
    if let problem = problems.first, let pinned = graph?.state(for: problem).pinned {
        StatementEditor(problem: problem, node: pinned)
    }
}
#endif
