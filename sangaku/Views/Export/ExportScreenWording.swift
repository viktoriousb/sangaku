import Foundation

/// What the export card and sheets say, kept out of the views so it is tested.
enum ExportScreenWording {
    /// Under the AI-use statement on Review's card.
    static func aiUseCaption(theorem: String?) -> String {
        let theorem = theorem ?? "the theorem"
        return "Generated from the record of who wrote and who checked each step and from each statement's status; it names roles, never people or models. The LaTeX export carries this text for \(theorem) and what it uses; the hashtag manuscript and the Lean project carry it for every statement."
    }

    /// What an export writes and runs, above its plan.
    static func explanation(_ kind: ExportKind) -> String {
        switch kind {
        case .latex:
            "One LaTeX file that compiles on its own: the theorem and the statements it uses, the steps of their proofs with who wrote and who checked each, each statement's status, the AI-use statement and the notation's macros. If pdfLaTeX is set up, it compiles the file offline in a sandbox first, and the PDF is written beside it."
        case .hashtag:
            "A hashtag manuscript of every statement. The first export runs the kit's kit.py new; every export then runs the manuscript's build.sh (the kit's, as the folder holds it) offline in a sandbox, and writes the folder only if the build and all its checks pass. Labels come from the statements' stable IDs, so their tags never change."
        case .leanProject:
            "A Lake project: the problem's Lean module exactly as the checks compiled it, from checked code only, requiring Mathlib \(LeanPin.mathlibRev); and a README saying where each check stands. Nothing runs; build it with Lake."
        }
    }

    /// Above the texts the gate refused.
    static let refusalsHeading = "Nothing can be exported until these are changed:"

    /// "5 files to write"; the manuscript also has its regions of the kit's files.
    static func toWrite(_ plan: ExportPlan) -> String {
        let regions = plan.regions?.asFiles.count ?? 0
        return Prose.count(plan.files.count, "file") + (regions > 0 ? " and " + Prose.count(regions, "region") : "")
            + " to write"
    }

    static func kit(_ label: String?) -> String {
        label.map { "Created with " + $0 + "." }
            ?? "The hashtag kit folder chosen in Settings cannot be used. Choose another there, or use the bundled kit."
    }

    /// The build's LaTeX line, with plurals as written.
    static func counts(_ counts: BuildReport.Counts) -> String {
        "LaTeX: " + [Prose.count(counts.errors, "error"), Prose.count(counts.undefined, "undefined reference"),
                     Prose.count(counts.twice, "label") + " defined twice", Prose.count(counts.unresolved, "unresolved link"),
                     Prose.count(counts.overfull, "overfull box", plural: "overfull boxes")]
            .joined(separator: ", ") + (counts.pages.map { ", " + Prose.count($0, "page") } ?? "") + "."
    }

    static func written(_ count: Int) -> String { Prose.count(count, "file") + " written" }

    static let noOutcome = "No export of this problem has run since the app opened."

    /// Under the plan: what happens on Export.
    static let onExport = "Nothing runs and nothing is written until you click Export. Every text passed the export's gate: prose is printed as typed, and mathematics may use only listed commands and the notation's macros."

    static func folder(_ state: ExportFolderState) -> String {
        switch state {
        case .empty:
            "An empty folder: the export creates its files here and commits them with git, in your name, so a later export can replace them safely."
        case .earlierExport:
            "An earlier export of this problem: its files are replaced and the change is committed with git, in your name. Changes of yours that aren't committed stop the export; your other files are kept."
        case .refused(let reason):
            reason
        }
    }

    /// Under a file in the plan.
    static func region(_ path: String) -> String? {
        guard let mark = path.firstIndex(of: "#") else { return nil }
        return "The app's part of \(path[..<mark]), between its % sangaku:begin and % sangaku:end lines."
    }

    /// The card's line for the last export.
    static func outcome(_ outcome: ExportOutcome) -> String {
        if let error = outcome.error { return outcome.kind.title + " not exported. " + error.message }
        let written = Prose.count(outcome.written.count, "file") + " written to " + outcome.folder + "."
        return outcome.kind.title + " exported: " + written
            + (outcome.notCompiled ? " pdfLaTeX is not set up, so the file was not compiled." : "")
            + (outcome.uncommitted.map { " It was not committed: " + $0 } ?? " Committed with git.")
    }

    static func checks(_ report: BuildReport) -> [String] {
        report.passed.map { "PASS " + $0 } + report.failed.map { "FAIL " + $0 }
            + report.missing.map { "Not reported: " + $0 }
    }
}
