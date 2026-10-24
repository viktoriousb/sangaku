import AppKit
import QuickLook
import SwiftData
import SwiftUI

/// Review's export card: a row for each export with what its folder holds now and its PDF in Quick Look, the running
/// export and how the last one ended, and the AI-use statement for the theorem and what it uses, exactly as the
/// exports write it (invariant 8), folded. Its own view, so its reads are tracked apart from the panel's step selection.
struct ExportCard: View {
    let problem: Problem
    /// Read by Review for the same people; the card does not read them again.
    let graph: StatementGraphState
    let verification: VerificationState

    @Query private var people: [Person]
    @Environment(\.exportService) private var export
    @Environment(\.exportActions) private var actions
    /// What each export's folder held when last read, read when the card appears and after every export.
    @State private var loaded: Loaded?
    /// Stands in for the folders in previews and renders, which read none.
    private let sample: [ExportKind: ExportOnDisk]?
    /// The PDF Quick Look shows.
    @State private var preview: URL?
    @SceneStorage("export.showsStatement") private var showsStatement = false

    init(problem: Problem, graph: StatementGraphState, verification: VerificationState,
         sample: [ExportKind: ExportOnDisk]? = nil) {
        self.problem = problem
        self.graph = graph
        self.verification = verification
        self.sample = sample
    }

    /// The rows, in order.
    static let kinds: [ExportKind] = [.hashtag, .latex, .leanProject]

    var body: some View {
        let problemID = problem.stableID
        let phase = export?.phases[problemID]
        let outcome = export?.outcomes[problemID]
        let folders = Dictionary(uniqueKeysWithValues: Self.kinds.compactMap { kind in
            export?.folder(for: problemID, kind: kind).map { (kind, $0) }
        })
        // Nil until this problem's folders are read: rows read for another problem are never shown.
        let rows = sample ?? (loaded?.problem == problemID ? loaded?.rows : nil)
        PanelCard(title: "Export") {
            VStack(spacing: 0) {
                ForEach(Array(Self.kinds.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Divider() }
                    ExportRow(kind: kind, copy: rows?[kind], folder: folders[kind], read: rows != nil,
                              busy: phase != nil, preview: $preview)
                        .padding(.vertical, 6)
                }
            }
            if let phase {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(phase.words).font(.callout)
                    Spacer()
                    Button("Stop Export") { actions?(.stop(problem: problemID)) }
                        .disabled(actions == nil)
                }
            }
            if let outcome {
                ExportOutcomeLine(outcome: outcome)
            }
            Divider()
            AIUseSection(problem: problem, people: Set(people.map(\.stableID)), graph: graph, verification: verification,
                         isExpanded: $showsStatement)
        }
        .task(id: DiskKey(problem: problemID, folders: folders, finished: outcome?.at)) {
            guard sample == nil else { return }
            let rows = await Self.read(folders, problem: problemID)
            // A read the card no longer wants (another problem, a newer export) leaves the rows alone.
            guard !Task.isCancelled else { return }
            loaded = Loaded(problem: problemID, rows: rows)
        }
        .quickLookPreview($preview)
    }

    private struct Loaded {
        var problem: UUID
        var rows: [ExportKind: ExportOnDisk]
    }

    /// What changes what the rows show: the problem, where each export goes, and an export ending.
    private struct DiskKey: Hashable {
        var problem: UUID
        var folders: [ExportKind: String]
        var finished: Date?
    }

    private static func read(_ folders: [ExportKind: String], problem: UUID) async -> [ExportKind: ExportOnDisk] {
        var found: [ExportKind: ExportOnDisk] = [:]
        for (kind, folder) in folders {
            found[kind] = await ExportOnDisk.read(folder: folder, kind: kind, problem: problem)
        }
        return found
    }
}

/// One export: its PDF's first page, what its folder holds, View, and Export or Update.
private struct ExportRow: View {
    let kind: ExportKind
    let copy: ExportOnDisk?
    /// The folder this export goes to, once one was chosen.
    let folder: String?
    /// The folder was read; until then the row says nothing about it.
    let read: Bool
    /// An export of the problem is running, so none can start.
    let busy: Bool
    @Binding var preview: URL?

    @Environment(\.exportActions) private var actions

    var body: some View {
        let pdf = copy?.pdf.map { URL(fileURLWithPath: $0) }
        let updates = copy != nil || (!read && folder != nil)
        let status = read || folder == nil ? ExportScreenWording.onDisk(copy, kind: kind, folder: folder, now: .now) : nil
        HStack(spacing: 10) {
            // The same as View, for the mouse: VoiceOver and Tab reach View instead.
            Group {
                if let pdf {
                    Button { preview = pdf } label: { ExportThumbnail(kind: kind, image: copy?.thumbnail) }
                        .buttonStyle(.plain)
                        .focusable(false)
                } else {
                    ExportThumbnail(kind: kind, image: nil)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.callout.weight(.medium))
                Text(status ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(status == nil)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                if let pdf {
                    Button("View") { preview = pdf }
                        .help("Opens the PDF in Quick Look")
                        .accessibilityLabel("View the \(kind.title) PDF")
                }
                Button(updates ? "Update…" : "Export…") { actions?(.open(kind)) }
                    .disabled(busy || actions == nil)
                    .accessibilityLabel((updates ? "Update the " : "Export the ") + kind.title)
            }
            .controlSize(.small)
        }
        .help(copy?.folder ?? "")
        .contextMenu {
            if let pdf { Button("View PDF") { preview = pdf } }
            if copy != nil { Button("Show in Finder") { showInFinder(pdf) } }
            Button(updates ? "Update…" : "Export…") { actions?(.open(kind)) }
                .disabled(busy || actions == nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
        .accessibilityActions {
            if copy != nil { Button("Show in Finder") { showInFinder(pdf) } }
        }
    }

    private func showInFinder(_ pdf: URL?) {
        guard let copy else { return }
        NSWorkspace.shared.activateFileViewerSelecting([pdf ?? URL(fileURLWithPath: copy.folder)])
    }
}

/// A PDF's first page, as Finder would show it; an icon for an export without one.
private struct ExportThumbnail: View {
    let kind: ExportKind
    let image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { Rectangle().strokeBorder(.separator, lineWidth: 0.5) }
            } else {
                Image(systemName: kind == .leanProject ? "folder" : "doc.text")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 52)
    }
}

/// The AI-use statement for the theorem and what it uses, folded, with Copy beside its name. It is read only when
/// shown or copied.
struct AIUseSection: View {
    let problem: Problem
    let people: Set<UUID>
    let graph: StatementGraphState
    let verification: VerificationState
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            let snapshot = snapshot()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(AIUseStatement.of(snapshot, scope: .theoremAndUses).paragraphMarkups.enumerated()),
                        id: \.offset) { _, paragraph in
                    MathText(paragraph)
                        .captionMath()
                        .textSelection(.enabled)
                }
                Text(ExportScreenWording.aiUseCaption(theorem: snapshot.theorem?.label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text(AIUseStatement.heading).font(.subheadline.weight(.semibold))
                Spacer()
                Button("Copy") { Pasteboard.copy(AIUseStatement.of(snapshot(), scope: .theoremAndUses).markup) }
                    .controlSize(.small)
                    .help("Copies the AI-use statement, with any mathematics in LaTeX.")
                    .accessibilityLabel("Copy Statement")
            }
        }
    }

    private func snapshot() -> ExportSnapshot {
        ExportSnapshot.read(problem: problem, people: people, graph: graph, verification: verification)
    }
}

/// How the last export ended, with its report and its folder.
private struct ExportOutcomeLine: View {
    let outcome: ExportOutcome

    @Environment(\.exportActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ExportScreenWording.outcome(outcome),
                  systemImage: outcome.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(outcome.succeeded ? Color.primary : ColorToken.refuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                if outcome.report != nil || !outcome.succeeded {
                    Button("Show Report…") { actions?(.showReport) }
                }
                if outcome.succeeded {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outcome.folder)])
                    }
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last export")
    }
}

#if DEBUG
#Preview("Export card", traits: .fixture) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query var people: [Person]
    ScrollView {
        if let problem = problems.first {
            let ids = Set(people.map(\.stableID))
            ExportCard(problem: problem, graph: .read(problem: problem, people: ids),
                       verification: .read(problem: problem, people: ids)).padding()
        }
    }
    .frame(width: 380, height: 700)
}
#endif
