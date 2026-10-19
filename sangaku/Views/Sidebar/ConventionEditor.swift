import SwiftData
import SwiftUI

/// Adds or edits one notation entry. Drafts stay local until Save; the manager validates the macro.
struct ConventionEditor: View {
    let problem: Problem
    let target: NotationEditorTarget

    @Environment(\.problemManager) private var problems
    @Environment(\.mathContext) private var mathContext
    @Environment(\.dismiss) private var dismiss

    @State private var symbol = ""
    @State private var meaning = ""
    @State private var macro = ""
    @State private var includeInContext = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit Convention" : "Add Convention").font(.headline)
            Form {
                TextField("Symbol (LaTeX)", text: $symbol, prompt: Text(#"\Syl_r(G)"#))
                    .font(.system(.body, design: .monospaced))
                LabeledContent("Preview") {
                    if symbol.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("—").foregroundStyle(.tertiary)
                    } else {
                        MathText(formula: symbol)
                            .environment(\.mathContext, previewContext)
                    }
                }
                TextField("Meaning", text: $meaning, prompt: Text("the set of Sylow r-subgroups of G"))
                TextField("Macro (optional)", text: $macro, prompt: Text(#"\DeclareMathOperator{\Syl}{Syl}"#))
                    .font(.system(.body, design: .monospaced))
                Toggle("Include in every model's context", isOn: $includeInContext)
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
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(symbol.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private var isEditing: Bool {
        if case .edit = target { true } else { false }
    }

    /// The preview renders with the macro being typed, when it parses.
    private var previewContext: MathContext {
        let typed = MacroParser.parse(macro).definitions
        guard !typed.isEmpty else { return mathContext }
        return MathContext(macros: MacroSet(Array(mathContext.macros.definitions.values) + typed), fontSize: mathContext.fontSize)
    }

    private func load() {
        guard case .edit(let entry) = target else { return }
        symbol = entry.symbolLaTeX
        meaning = entry.meaning
        macro = entry.macroDefinition ?? ""
        includeInContext = entry.includeInContext
    }

    private func save() {
        guard let problems else { return }
        do {
            switch target {
            case .add:
                try problems.addConvention(to: problem, symbolLaTeX: symbol, meaning: meaning,
                                           macroDefinition: macro, includeInContext: includeInContext)
            case .edit(let entry):
                try problems.updateConvention(entry, symbolLaTeX: symbol, meaning: meaning,
                                              macroDefinition: macro, includeInContext: includeInContext)
            }
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}

#if DEBUG
#Preview("Add convention", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first {
        ConventionEditor(problem: problem, target: .add)
    }
}
#endif
