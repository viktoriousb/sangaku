import Foundation

/// A problem's notation as values: the macros for rendering, the rows for display, and what goes into prompts.
/// Built from `NotationEntry` records; safe to hand to background code (Milestone 2's `ContextBuilder`).
nonisolated struct NotationRegistry: Hashable, Sendable {
    nonisolated struct Row: Hashable, Sendable, Identifiable {
        var id: UUID
        var symbolLaTeX: String
        var meaning: String
        var macroDefinition: String?
        var includeInContext: Bool
    }

    /// An entry whose macro definition did not parse.
    nonisolated struct Diagnostic: Hashable, Sendable {
        var entryID: UUID
        var message: String
    }

    var rows: [Row]
    var macros: MacroSet
    var diagnostics: [Diagnostic]

    init(rows: [Row]) {
        self.rows = rows
        var definitions: [MacroDefinition] = []
        var diagnostics: [Diagnostic] = []
        for row in rows {
            guard let source = row.macroDefinition, !source.isEmpty else { continue }
            let parsed = MacroParser.parse(source)
            definitions += parsed.definitions
            for skipped in parsed.skipped {
                diagnostics.append(Diagnostic(entryID: row.id, message: skipped.reason))
            }
            if parsed.definitions.isEmpty && parsed.skipped.isEmpty {
                diagnostics.append(Diagnostic(entryID: row.id, message: "No macro definition found"))
            }
        }
        self.macros = MacroSet(definitions)
        self.diagnostics = diagnostics
    }

    /// The notation block every prompt carries (invariant 5): only entries marked for context.
    func promptBlock() -> String {
        rows.filter(\.includeInContext).map { row in
            var line = "- $\(row.symbolLaTeX)$: \(row.meaning)"
            if let macro = row.macroDefinition, !macro.isEmpty { line += " (macro: \(macro))" }
            return line
        }.joined(separator: "\n")
    }
}

extension NotationRegistry {
    init(entries: [NotationEntry]) {
        self.init(rows: entries.map {
            Row(id: $0.stableID, symbolLaTeX: $0.symbolLaTeX, meaning: $0.meaning,
                macroDefinition: $0.macroDefinition, includeInContext: $0.includeInContext)
        })
    }
}
