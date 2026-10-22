import Foundation

/// The app's parts of `main.tex` and `preamble.tex`: each between `% sangaku:begin <name>` and `% sangaku:end <name>`,
/// so an export replaces them and nothing else in those files.
nonisolated struct HashtagRegions: Hashable, Sendable {
    var title: TeXFragment
    var chapters: TeXFragment
    var notation: TeXFragment

    /// What the plan shows and the approval binds: each region by file and name.
    var asFiles: [ExportFile] {
        [ExportFile(path: "manuscript/main.tex#title", contents: title.source),
         ExportFile(path: "manuscript/main.tex#chapters", contents: chapters.source),
         ExportFile(path: "manuscript/preamble.tex#notation", contents: notation.source)]
    }
}

/// Why a kit file could not take the app's regions.
nonisolated enum HashtagPatchError: Error, Hashable, Sendable {
    /// The kit's `main.tex` does not hold the line the app replaces on a first export.
    case unexpectedKitFile(String)
    /// A file of an earlier export lost the app's markers.
    case missingMarkers(String)

    var message: String {
        switch self {
        case .unexpectedKitFile(let file):
            "The hashtag kit's \(file) is not the one this version of the app expects. Choose the current kit in Settings."
        case .missingMarkers(let file):
            "\(file) no longer holds the app's markers (% sangaku:begin … and % sangaku:end …). Restore them from git, then export again."
        }
    }
}

/// The hashtag manuscript: the kit's project with the app's chapter, preface, status appendix and bibliography, and
/// its regions of `main.tex` and `preamble.tex`. Every text was gated when the document was composed.
nonisolated enum HashtagWriter {
    /// The files the app patches by region.
    static let patchedFiles = ["manuscript/main.tex", "manuscript/preamble.tex"]
    /// The kit's example chapter, removed on a first export.
    static let kitExample = "manuscript/ch1-setting.tex"

    /// `sangaku-1a2b3c4d5e6f`: fixed by the problem, so tags never change.
    static func salt(_ problem: UUID) -> String { "sangaku-" + LeanNaming.short(problem) }

    /// The title `kit.py new` gets: ASCII it accepts as is, or a neutral one. The app writes the real title itself.
    static func kitTitle(_ title: String) -> String {
        let kept = String(title.filter { $0.isASCII && ($0.isLetter || $0.isNumber || " .,:;'()-".contains($0)) })
            .split(separator: " ").joined(separator: " ")
        return kept.count >= 3 ? String(kept.prefix(120)) : "Exported problem"
    }

    static func files(_ document: ExportDocument) -> [ExportFile] {
        [ExportFile(path: "manuscript/preface.tex", contents: preface(document).source),
         ExportFile(path: "manuscript/ch1-results.tex", contents: chapter(document).source),
         ExportFile(path: "manuscript/appendix-status.tex", contents: appendix(document).source),
         ExportFile(path: "manuscript/refs.bib", contents: bibliography(document).source)]
    }

    static func regions(_ document: ExportDocument) -> HashtagRegions {
        HashtagRegions(
            title: "\\title{\\bfseries " + document.title + "}\n",
            chapters: "\\input{ch1-results}\n",
            notation: "% The problem's notation and what the exported items need. Replaced on every export.\n"
                + "\\theoremstyle{plain}\n\\newitem{claim}{Claim}\n\\usepackage{mathrsfs}\n" + LatexWriter.itemMacros
                + TeXFragment.joined(document.macros.map { $0 + "\n" }))
    }

    // MARK: Files

    static func preface(_ document: ExportDocument) -> TeXFragment {
        var out: TeXFragment = "\\chapter*{Preface}\\label{ch:preface}\n\n"
            + "% Generated from the problem's record. Export again rather than editing: an export replaces this file.\n\n"
        if let theorem = document.theorem {
            out += "The main result is " + reference(theorem) + ". Its status: " + theorem.statusWords + ".\n"
        } else if let open = document.items.first(where: { $0.group == .open && $0.environment == .conjecture }) {
            out += "No theorem has a proof here. The first open statement is " + reference(open) + ".\n"
        } else {
            out += "No theorem has a proof here.\n"
        }

        out += "\n\\subsection*{The argument}\n"
        if document.argument.isEmpty {
            out += "No proof steps are recorded.\n"
        } else {
            out += "The proof as recorded goes through these steps:\n\\begin{enumerate}[label=\\textup{(\\arabic*)}]\n"
            for step in document.argument { out += "\\item " + step + "\n" }
            out += "\\end{enumerate}\n"
        }

        out += "\n\\subsection*{What is imported}\n"
        let imported = document.items.filter { $0.group == .imported }
        if imported.isEmpty {
            out += "Nothing is imported.\n"
        } else {
            out += "\\begin{itemize}\n"
            for item in imported {
                out += "\\item " + reference(item) + ", from " + (item.importedSource ?? .empty) + "; not checked here.\n"
            }
            out += "\\end{itemize}\n"
        }

        out += "\n\\subsection*{Provenance and status}\n"
            + "This document was generated from the record kept for the problem. Each statement's status is stated with it "
            + "and listed in Appendix~\\ref{ch:status}; \\emph{checked internally only} means checked within that record. "
            + "This document has not been refereed.\n\n"
            + "\\paragraph{Use of AI} " + TeXFragment.joined(document.aiUse, separator: "\n\n") + "\n"

        out += "\n\\subsection*{Conventions}\n"
        if document.notation.isEmpty {
            out += "No notation is recorded.\n"
        } else {
            out += "\\begin{itemize}\n"
            for line in document.notation { out += "\\item " + line.symbol + ": " + line.meaning + "\n" }
            out += "\\end{itemize}\n"
        }
        return out
    }

    /// One chapter, a section per group, a subsection per statement: every item lies in a numbered subsection with
    /// its label right after its title, as the kit's audit requires.
    static func chapter(_ document: ExportDocument) -> TeXFragment {
        var out: TeXFragment = "\\chapter{Results}\\label{ch:results}\n\n"
            + "% Generated from the problem's record. Export again rather than editing: an export replaces this file.\n"
        for group in ExportDocument.Group.allCases {
            let items = document.items.filter { $0.group == group }
            guard !items.isEmpty else { continue }
            out += "\n\\section{" + heading(group) + "}\\label{sec:" + sectionLabel(group) + "}\n"
            for item in items {
                out += "\n\\subsection{" + item.name + "}\\label{" + TeXGate.subsectionLabel(item.id) + "}\n"
                out += LatexWriter.item(item, refutation: false)
                if let refutation = item.refutation {
                    out += "\n\\begin{counterexample}\\label{" + TeXGate.counterexampleLabel(item.id) + "}\n"
                        + refutation + "\n\\end{counterexample}\n"
                }
            }
        }
        return out
    }

    static func appendix(_ document: ExportDocument) -> TeXFragment {
        var out: TeXFragment = "\\chapter{Status of Statements}\\label{ch:status}\n\n"
            + "% Generated from the problem's record. Export again rather than editing: an export replaces this file.\n\n"
            + "Every numbered statement, by its status in the problem's record. \\emph{Checked internally only} means checked "
            + "within that record; nothing here was refereed.\n\n"
            + "\\begin{center}\n\\small\n\\begin{tabular}{@{}p{0.24\\linewidth}p{0.16\\linewidth}p{0.5\\linewidth}@{}}\n"
            + "\\toprule\nItem & Label & Status \\\\\n\\midrule\n"
        for item in document.items {
            var status = item.statusWords
            if let source = item.importedSource { status += "; from " + source }
            out += reference(item) + " & " + item.name + " & " + status + " \\\\\n"
        }
        return out + "\\bottomrule\n\\end{tabular}\n\\end{center}\n"
    }

    /// From what the indexes returned only, and only for citations whose fields BibTeX reads as written.
    static func bibliography(_ document: ExportDocument) -> TeXFragment {
        var out: TeXFragment = "% Bibliography of this document, from what arXiv or zbMATH Open returned for citations found there.\n"
            + "% Generated on every export: never invented, never edited by hand.\n"
        for reference in document.references {
            out += "\n@misc{" + reference.key + ",\n  author = {" + TeXFragment.joined(reference.authors, separator: " and ")
                + "},\n  title = {" + reference.title + "},\n"
            if let year = reference.year { out += "  year = {" + TeXFragment(year) + "},\n" }
            if let link = reference.link { out += "  howpublished = {" + link + "},\n" }
            out += "  note = {Matched in " + reference.index + ".}\n}\n"
        }
        return out
    }

    /// "Lemma~\ref{lem:s…}", by the environment the item is written in.
    static func reference(_ item: ExportDocument.Item) -> TeXFragment {
        item.environment.word + "~\\ref{" + item.label + "}"
    }

    private static func heading(_ group: ExportDocument.Group) -> TeXFragment {
        switch group {
        case .imported: "Imported results"
        case .lemmas: "Lemmas and claims"
        case .main: "The main theorem"
        case .open: "Conjectures and open statements"
        case .refuted: "Refuted statements"
        }
    }

    private static func sectionLabel(_ group: ExportDocument.Group) -> TeXFragment {
        switch group {
        case .imported: "imported"
        case .lemmas: "lemmas"
        case .main: "main"
        case .open: "open"
        case .refuted: "refuted"
        }
    }

    // MARK: Regions

    static func marker(_ edge: String, _ name: String) -> String { "% sangaku:" + edge + " " + name }

    /// The kit's `main.tex` as `kit.py new` wrote it, with the title line and the example chapter's input replaced by
    /// the app's regions.
    static func firstMain(_ kit: String, regions: HashtagRegions) throws(HashtagPatchError) -> String {
        var lines = kit.components(separatedBy: "\n")
        guard let title = lines.firstIndex(where: { $0.hasPrefix("\\title{\\bfseries ") }),
              let example = lines.firstIndex(of: "\\input{ch1-setting}") else {
            throw .unexpectedKitFile("manuscript/main.tex")
        }
        lines[example] = block("chapters", regions.chapters)
        lines[title] = block("title", regions.title)
        return lines.joined(separator: "\n")
    }

    /// The kit's `preamble.tex` with the app's notation region at its end.
    static func firstPreamble(_ kit: String, regions: HashtagRegions) -> String {
        (kit.hasSuffix("\n") ? kit : kit + "\n") + "\n" + block("notation", regions.notation) + "\n"
    }

    /// A file of an earlier export with each of the app's regions replaced. Refused when a marker is missing.
    static func update(_ text: String, file: String, regions: [(String, TeXFragment)]) throws(HashtagPatchError) -> String {
        var lines = text.components(separatedBy: "\n")
        for (name, content) in regions {
            guard let begin = lines.firstIndex(of: marker("begin", name)),
                  let end = lines[begin...].firstIndex(of: marker("end", name)) else { throw .missingMarkers(file) }
            lines.replaceSubrange(begin...end, with: [block(name, content)])
        }
        return lines.joined(separator: "\n")
    }

    private static func block(_ name: String, _ content: TeXFragment) -> String {
        let body = content.source.hasSuffix("\n") ? String(content.source.dropLast()) : content.source
        return marker("begin", name) + "\n" + body + "\n" + marker("end", name)
    }
}
