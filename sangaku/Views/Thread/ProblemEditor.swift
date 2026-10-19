import SwiftData
import SwiftUI

/// Edits a problem's title and statement against a live preview, and which providers it may be sent to.
/// Keystrokes stay in local drafts; Save commits one change.
struct ProblemEditor: View {
    let problem: Problem

    @Environment(\.problemManager) private var problems
    @Environment(\.mathContext) private var mathContext
    @Environment(\.threadManager) private var threads
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var statement = ""
    @State private var providers: [ProviderChoice] = []
    /// The theorem's wording was checked against Lean, so the statement can no longer change.
    @State private var locked = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Problem").font(.headline)
            TextField("Title", text: $title, prompt: Text(#"Normal Sylow subgroups, $|G| = p^2q$"#))
            Text("Statement · LaTeX, with $…$ for inline and $$…$$ for display math")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $statement)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .border(.separator)
                .disabled(locked)
            if locked {
                Text(StatementError.textLockedByLeanCheck.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                MathText(statement.isEmpty ? " " : statement)
                    .environment(\.mathContext, MathContext(macros: mathContext.macros, fontSize: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 200)
            if !providers.isEmpty {
                Text("Allowed providers · nothing about this problem is sent to a provider it does not allow")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach($providers) { $provider in
                    Toggle(provider.name, isOn: $provider.allowed)
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
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear {
            title = problem.title
            statement = problem.statementLaTeX
            locked = problems?.statementIsLocked(problem) ?? false
            providers = (threads?.registry.descriptors ?? []).map {
                ProviderChoice(id: $0.id, name: $0.displayName, allowed: problem.allowedProviderIDs.contains($0.id))
            }
        }
    }
}

extension ProblemEditor {
    private func save() {
        guard let problems else { return }
        do {
            try problems.update(problem, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                statementLaTeX: statement)
        } catch {
            self.error = error.message
            return
        }
        for provider in providers {
            problems.setProvider(provider.id, allowed: provider.allowed, for: problem)
        }
        dismiss()
    }
}

/// One provider's toggle in the editor's draft.
private struct ProviderChoice: Identifiable {
    let id: String
    let name: String
    var allowed: Bool
}

#if DEBUG
#Preview("Edit problem", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first {
        ProblemEditor(problem: problem)
    }
}
#endif
