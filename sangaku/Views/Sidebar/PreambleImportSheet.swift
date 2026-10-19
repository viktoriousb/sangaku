import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Imports macro definitions from a pasted preamble or a .tex file. Shows what will be imported and what will
/// be skipped (with reasons) before anything changes.
struct PreambleImportSheet: View {
    let problem: Problem

    @Environment(\.problemManager) private var problems
    @Environment(\.dismiss) private var dismiss

    @State private var source = ""
    @State private var choosingFile = false
    @State private var fileError: String?
    @State private var report: PreambleImportReport?

    var body: some View {
        let parsed = MacroParser.parse(source)
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Preamble").font(.headline)
            if let report {
                ImportReportView(report: report)
            } else {
                Text("Paste a preamble or open a .tex file. Only macro definitions are imported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $source)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .border(.separator)
                if let fileError {
                    Label(fileError, systemImage: "exclamationmark.triangle").foregroundStyle(ColorToken.refuted.color)
                }
                ParsePreview(result: parsed)
            }
            HStack {
                if report == nil {
                    Button("Open .tex File…") { choosingFile = true }
                }
                Spacer()
                if report == nil {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Import \(Prose.count(parsed.definitions.count, "Definition"))") {
                        report = problems?.importPreamble(source, into: problem)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed.definitions.isEmpty)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .fileImporter(isPresented: $choosingFile,
                      allowedContentTypes: [UTType(filenameExtension: "tex") ?? .plainText, .plainText]) { result in
            load(result)
        }
    }

    private func load(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            source = try String(contentsOf: url, encoding: .utf8)
            fileError = nil
        } catch {
            fileError = "Could not read the file: \(error.localizedDescription)"
        }
    }
}

private struct ParsePreview: View {
    let result: MacroParseResult

    var body: some View {
        if !result.definitions.isEmpty || !result.skipped.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(result.definitions.enumerated()), id: \.offset) { _, definition in
                    Label(definition.canonicalSource, systemImage: "checkmark")
                        .font(.system(.caption, design: .monospaced))
                }
                ForEach(Array(result.skipped.enumerated()), id: \.offset) { _, skipped in
                    Label("Line \(skipped.line): \(skipped.reason)", systemImage: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(skipped.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ImportReportView: View {
    let report: PreambleImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !report.added.isEmpty {
                Text("Added: \(report.added.map { "\\" + $0 }.joined(separator: ", "))")
            }
            if !report.updated.isEmpty {
                Text("Updated: \(report.updated.map { "\\" + $0 }.joined(separator: ", "))")
            }
            if report.added.isEmpty && report.updated.isEmpty {
                Text("Nothing changed: every definition was already in the registry.")
            }
            ForEach(Array(report.skipped.enumerated()), id: \.offset) { _, skipped in
                Text("Skipped line \(skipped.line): \(skipped.reason)")
                    .foregroundStyle(.secondary)
            }
            Text("New entries have no meaning yet; add one from the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

#if DEBUG
#Preview("Import from preamble", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first {
        PreambleImportSheet(problem: problem)
    }
}
#endif
