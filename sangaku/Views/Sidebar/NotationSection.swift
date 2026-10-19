import SwiftUI

/// The notation registry: conventions sent with every prompt, and the macros every formula is rendered with.
struct NotationSection: View {
    let problem: Problem

    @Environment(\.problemManager) private var problems
    @State private var editing: NotationEditorTarget?
    @State private var importing = false

    var body: some View {
        let diagnostics = problems?.notation(for: problem).diagnostics ?? []
        Section {
            Text("Pinned. Sent with every prompt, to every model.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(problem.sortedNotation) { entry in
                NotationRow(entry: entry, problem: diagnostics.first { $0.entryID == entry.stableID }?.message)
                    .contextMenu {
                        Button("Edit Convention…") { editing = .edit(entry) }
                        Toggle("Include in Model Context", isOn: Binding(
                            get: { entry.includeInContext },
                            set: { problems?.setIncludeInContext(entry, $0) }))
                        Divider()
                        Button("Delete Convention", role: .destructive) { problems?.deleteConvention(entry) }
                    }
            }
            NotationActions(add: { editing = .add }, importPreamble: { importing = true })
            // Sheets hang off this one row, not the Section, so a List never applies them per row.
            .sheet(item: $editing) { target in
                ConventionEditor(problem: problem, target: target)
            }
            .sheet(isPresented: $importing) {
                PreambleImportSheet(problem: problem)
            }
        } header: {
            Text("Notation")
        }
    }
}

/// Add and import, side by side when the sidebar is wide enough and stacked when it is not, so a narrow sidebar
/// never clips them.
struct NotationActions: View {
    let add: () -> Void
    let importPreamble: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttons }
            VStack(alignment: .leading, spacing: 4) { buttons }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    @ViewBuilder private var buttons: some View {
        Button("Add Convention", systemImage: "plus", action: add)
        Button("Import from Preamble…", systemImage: "square.and.arrow.down", action: importPreamble)
    }
}

private struct NotationRow: View {
    let entry: NotationEntry
    /// Why this entry's macro did not parse, if it did not.
    let problem: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MathText(formula: entry.symbolLaTeX, showsProblems: false)
                .environment(\.mathContext, mathContext)
                .frame(minWidth: 44, alignment: .leading)
            if entry.meaning.isEmpty {
                Text("No meaning yet").font(.callout).foregroundStyle(.tertiary)
            } else {
                MathText(entry.meaning, showsProblems: false)
                    .environment(\.mathContext, mathContext)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if !entry.includeInContext {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
                    .help("Not sent to models")
                    .accessibilityLabel("Not sent to models")
            }
            if let problem {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ColorToken.refuted.color)
                    .help(problem)
                    .accessibilityLabel(problem)
            }
        }
        .help(entry.macroDefinition ?? entry.meaning)
    }

    @Environment(\.mathContext) private var inherited
    private var mathContext: MathContext {
        var context = inherited
        context.fontSize = 13
        return context
    }
}

enum NotationEditorTarget: Identifiable {
    case add
    case edit(NotationEntry)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let entry): entry.stableID.uuidString
        }
    }
}
