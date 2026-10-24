import AppKit
import PDFKit

/// An export as its folder holds it now, for Review's export card: read from disk off the main actor, and only when
/// the folder's manifest says it is this problem's export of this kind.
nonisolated struct ExportOnDisk: Sendable {
    var folder: String
    /// The PDF the export built: the manuscript's, or the one beside the LaTeX file. Nil for the Lean project, or
    /// when pdfLaTeX was not set up.
    var pdf: String?
    var pages: Int?
    /// When the PDF was built, else when the export was written.
    var modified: Date?
    /// The PDF's first page.
    var thumbnail: CGImage?

    /// The thumbnail's size in pixels: the card shows it at half, for a Retina screen.
    static let thumbnailSize = CGSize(width: 80, height: 104)

    @concurrent
    static func read(folder: String, kind: ExportKind, problem: UUID) async -> ExportOnDisk? {
        guard ExportFolder.state(folder, kind: kind, problem: problem) == .earlierExport else { return nil }
        let manager = FileManager.default
        let pdf = ExportFolder.pdf(in: folder, kind: kind)
        let dated = pdf ?? folder + "/" + ExportManifest.fileName
        var copy = ExportOnDisk(folder: folder, pdf: pdf,
                                modified: (try? manager.attributesOfItem(atPath: dated))?[.modificationDate] as? Date)
        if let pdf, let document = PDFDocument(url: URL(fileURLWithPath: pdf)) {
            copy.pages = document.pageCount
            copy.thumbnail = document.page(at: 0)?.thumbnail(of: thumbnailSize, for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return copy
    }
}

nonisolated extension ExportFolder {
    /// The PDF an export of `kind` built in `folder`: the manuscript's `main.pdf`, or the newest PDF beside a LaTeX
    /// file of the same name. Nil for the Lean project.
    static func pdf(in folder: String, kind: ExportKind, fileManager: FileManager = .default) -> String? {
        switch kind {
        case .hashtag:
            let path = folder + "/manuscript/main.pdf"
            return fileManager.fileExists(atPath: path) ? path : nil
        case .latex:
            let entries = Set((try? fileManager.contentsOfDirectory(atPath: folder)) ?? [])
            let built = entries.filter { $0.hasSuffix(".pdf") && entries.contains(String($0.dropLast(4)) + ".tex") }
            func modified(_ name: String) -> Date {
                ((try? fileManager.attributesOfItem(atPath: folder + "/" + name))?[.modificationDate] as? Date) ?? .distantPast
            }
            return built.max { modified($0) < modified($1) }.map { folder + "/" + $0 }
        case .leanProject:
            return nil
        }
    }
}
