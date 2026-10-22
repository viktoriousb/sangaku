import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What an export would write, read fresh whenever the folder changes: the folder and where it stands, every file
/// and region in full, and any text the gate refused. Export carries the digest of what is shown.
struct ExportPlanSheet: View {
    let problem: Problem
    let kind: ExportKind

    @Environment(\.exportService) private var export
    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var plan: ExportPlan?
    @State private var refusals: [ExportRefusal] = []
    @State private var error: String?
    @State private var choosing = false
    @State private var starting = false
    /// The folder this kind was last exported to has been looked up.
    @State private var seeded = false

    /// `plan`: what to show before the first reading (previews).
    init(problem: Problem, kind: ExportKind, plan: ExportPlan? = nil) {
        self.problem = problem
        self.kind = kind
        _plan = State(initialValue: plan)
        _folder = State(initialValue: plan?.request.folder ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export " + kind.title).font(.title2)
            Text(ExportScreenWording.explanation(kind))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                    Text(folder.isEmpty ? "Not chosen" : folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Choose…") { choosing = true }
            }
            // A group a VoiceOver user enters, so Choose… is heard with what it chooses.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Folder")
            if kind == .hashtag, let plan {
                Text(ExportScreenWording.kit(plan.kit)).font(.callout).foregroundStyle(.secondary)
            }
            if let plan {
                Label(ExportScreenWording.folder(plan.folder),
                      systemImage: plan.folder.refusal == nil ? "folder" : "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(plan.folder.refusal == nil ? Color.secondary : ColorToken.refuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !refusals.isEmpty { refusalList }
            if let plan { files(plan) }
            Text(ExportScreenWording.onExport)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SheetErrorLine(error: error)
            SheetButtons(confirm: "Export", disabled: plan == nil || plan?.folder.refusal != nil || starting) { start() }
        }
        .padding(20)
        .frame(width: 640)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folder = ProcessExecutor.canonical(url.path(percentEncoded: false)) }
        }
        .task(id: folder) {
            // The first reading starts from the folder this kind was last exported to, read once.
            if !seeded {
                seeded = true
                if folder.isEmpty, let last = export?.folder(for: problem.stableID, kind: kind) {
                    folder = last
                    return
                }
            }
            await replan()
        }
    }

    private var refusalList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ExportScreenWording.refusalsHeading, systemImage: "exclamationmark.triangle")
                .foregroundStyle(ColorToken.refuted.color)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(refusals.enumerated()), id: \.offset) { _, refusal in
                        Text(refusal.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
    }

    private func files(_ plan: ExportPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ExportScreenWording.toWrite(plan)).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.shown, id: \.path) { file in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 4) {
                                if let note = ExportScreenWording.region(file.path) {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                                ToolTextBox(text: file.contents, label: file.path)
                            }
                        } label: {
                            Text(file.path).font(.callout.monospaced())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
        }
    }

    private func replan() async {
        guard let export else { return }
        do throws(ExportError) {
            plan = try await export.plan(ExportRequest(problemID: problem.stableID, kind: kind, folder: folder))
            refusals = []
            error = nil
        } catch {
            plan = nil
            if case .refused(let list) = error {
                refusals = list
                self.error = nil
            } else {
                refusals = []
                self.error = error.message
            }
        }
    }

    private func start() {
        guard let export, let plan else { return }
        starting = true
        Task {
            do throws(ExportError) {
                try await export.start(plan.request, shown: plan.digest)
                dismiss()
            } catch {
                // Read again first: a successful reading clears the error line.
                await replan()
                self.error = error.message
            }
            starting = false
        }
    }
}

/// How the last export of the problem ended: what was written, or why nothing was; and the kit's build report, with
/// each statement's label named.
struct ExportReportSheet: View {
    let problem: Problem
    let outcome: ExportOutcome?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Report").font(.title2)
            if let outcome {
                Text(ExportScreenWording.outcome(outcome))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let report = outcome.report {
                    if let counts = report.counts {
                        Text(ExportScreenWording.counts(counts)).font(.callout)
                    }
                    ForEach(ExportScreenWording.checks(report), id: \.self) { line in
                        Text(line).font(.callout.monospaced())
                    }
                    ToolTextBox(text: BuildReport.annotated(report.output, names: names), label: "Build output")
                }
                if !outcome.written.isEmpty {
                    DisclosureGroup(ExportScreenWording.written(outcome.written.count)) {
                        ToolTextBox(text: outcome.written.joined(separator: "\n"), label: "Files written")
                    }
                }
            } else {
                Text(ExportScreenWording.noOutcome).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    /// Each statement's label by the twelve hex digits its TeX label carries.
    private var names: [String: String] {
        Dictionary((problem.statements ?? []).map { (LeanNaming.short($0.stableID), $0.label) },
                   uniquingKeysWith: { first, _ in first })
    }
}

#if DEBUG
#Preview("Export plan", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first {
        ExportPlanSheet(problem: problem, kind: .hashtag)
    }
}

#Preview("Export report", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first {
        ExportReportSheet(problem: problem, outcome: ExportOutcome(
            kind: .hashtag, folder: "/Users/someone/papers/sylow", error: .build(ExportPreviewData.failedBuild),
            report: ExportPreviewData.failedBuild, at: .now))
    }
}

/// A build report as `build.sh` prints it when an item lacks its label.
enum ExportPreviewData {
    static let failedBuild = BuildReport.read("""
        LaTeX: 0 errors, 0 undefined references, 0 labels defined twice, 0 unresolved links, 1 overfull boxes, 7 pages (3 passes)
        PASS tags (11 in manuscript/htag-index.md)
        PASS frozen files unchanged
        PASS every reference is defined
        PASS no label is defined twice
        FAIL every item has a label               lemma ch1-results.tex:40
        PASS every item lies in a subsection
        """, exitedCleanly: false)
}
#endif
