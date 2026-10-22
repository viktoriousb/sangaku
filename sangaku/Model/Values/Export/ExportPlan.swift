import Foundation

/// What can be exported.
nonisolated enum ExportKind: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case latex, hashtag, leanProject

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latex: "LaTeX"
        case .hashtag: "hashtag Manuscript"
        case .leanProject: "Lean Project"
        }
    }
}

/// An export the person asked for: which problem, what, and into which folder.
nonisolated struct ExportRequest: Hashable, Sendable {
    var problemID: UUID
    var kind: ExportKind
    var folder: String
}

/// The folder an export writes into, as it stands before anything is written.
nonisolated enum ExportFolderState: Hashable, Sendable {
    /// Empty, or holding only a git repository: a first export.
    case empty
    /// An earlier export of this problem and kind: the app's files are replaced, once git shows them committed.
    case earlierExport
    /// Anything else: nothing is written.
    case refused(String)

    var refusal: String? {
        if case .refused(let reason) = self { reason } else { nil }
    }
}

/// What an export will write, shown before anything runs. The click carries `digest`; the export re-plans and goes
/// ahead only if the new plan has the same digest, and every file it writes comes from the plan in the approval.
nonisolated struct ExportPlan: Hashable, Sendable {
    var request: ExportRequest
    /// Files written whole, by their path in the folder.
    var files: [ExportFile]
    /// The app's regions of the kit's files (the manuscript only).
    var regions: HashtagRegions?
    var folder: ExportFolderState
    /// The hashtag kit the manuscript is created with (`KitInfo.label`); nil when the kit chosen in Settings cannot be
    /// used.
    var kit: String?
    var digest: TextDigest

    init(request: ExportRequest, files: [ExportFile], regions: HashtagRegions?, folder: ExportFolderState,
         kit: String? = nil) {
        self.request = request
        self.files = files
        self.regions = regions
        self.folder = folder
        self.kit = kit
        let shown = (files + (regions?.asFiles ?? [])).sorted { $0.path < $1.path }
            .map { $0.path + "\u{0}" + $0.contents }
        digest = TextDigest(of: ([request.kind.rawValue, request.folder, kit ?? ""] + shown).joined(separator: "\u{0}"))
    }

    /// Everything the sheet lists: whole files, then regions.
    var shown: [ExportFile] { files + (regions?.asFiles ?? []) }
}

/// A person's click on Export for exactly the plan the sheet showed (the counterpart of `Approval` for code that
/// runs: here, TeX the kit's build compiles). Made only by `given`.
nonisolated struct ExportApproval: Hashable, Sendable {
    let person: PersonID
    let plan: ExportPlan
    let givenAt: Date

    private init(person: PersonID, plan: ExportPlan, at date: Date) {
        self.person = person
        self.plan = plan
        givenAt = date
    }

    /// `shown` is the digest the click carried; it must be the digest of the plan made again at the click.
    static func given(by person: PersonID, shown: TextDigest, planned: ExportPlan,
                      at date: Date) throws(Approval.Refusal) -> ExportApproval {
        guard planned.digest == shown else { throw .changedSinceShown }
        return ExportApproval(person: person, plan: planned, at: date)
    }
}

/// `.sangaku-export.json`: which problem and kind a folder holds, so a later export recognises its own folder. No
/// path, name or secret.
nonisolated struct ExportManifest: Codable, Hashable, Sendable {
    static let fileName = ".sangaku-export.json"

    var format = 1
    var kind: ExportKind
    var problem: UUID

    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}
