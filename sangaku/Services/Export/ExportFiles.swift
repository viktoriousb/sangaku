import CryptoKit
import Foundation

/// The hashtag kit a manuscript is created with: the copy pinned into the app, or a kit folder chosen in Settings.
nonisolated struct KitInfo: Hashable, Sendable {
    nonisolated enum Source: Hashable, Sendable {
        /// The copy bundled with the app, pinned from this commit of the kit.
        case bundled(commit: String)
        case folder(String)
    }

    var source: Source
    var version: String

    /// "hashtag 1.0, bundled with the app": what the plan shows and the click binds.
    var label: String {
        switch source {
        case .bundled(let commit): "hashtag \(version), bundled with the app (commit \(commit))"
        case .folder(let path): "hashtag \(version) from \(path)"
        }
    }
}

/// The copy of the kit pinned into the app (`Resources/Export/HashtagKit.json`, written by
/// `scripts/pin-hashtag-kit.py` from a committed kit).
nonisolated struct PinnedKit: Codable, Hashable, Sendable {
    nonisolated struct File: Codable, Hashable, Sendable {
        var path: String
        var executable: Bool
        var contents: String
    }

    var format: Int
    var version: String
    var commit: String
    var files: [File]

    /// Read once from the app's resources; nil if they lack it.
    static let bundled: PinnedKit? = Bundle.main.url(forResource: "HashtagKit", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(PinnedKit.self, from: $0) }

    func contents(_ path: String) -> String? { files.first { $0.path == path }?.contents }
}

nonisolated enum HashtagKit {
    /// What `kit.py new` and the build need, relative to the kit's folder.
    static let required = [
        "kit.py", "VERSION", "htag_paper.cls", "htag.sty", "template/build.sh", "template/compile_one.sh",
        "template/computations/crossref_audit.py", "template/manuscript/main.tex", "template/manuscript/preamble.tex",
        "template/manuscript/preface.tex", "template/manuscript/ch1-setting.tex",
        "template/manuscript/appendix-status.tex", "template/manuscript/refs.bib",
    ]

    /// The kit to create manuscripts with: the folder chosen in Settings when there is one, else the bundled copy.
    /// Either is checked to be the kit this app writes for.
    static func resolve(_ folder: String?, pinned: PinnedKit? = PinnedKit.bundled,
                        fileManager: FileManager = .default) throws(ExportError) -> KitInfo {
        if let folder, !folder.isEmpty {
            if fileManager.fileExists(atPath: folder + "/htag_manual.cls") {
                throw .kit("The kit folder in Settings holds an earlier hashtag kit (htag_manual). Choose the current kit, or use the bundled one.")
            }
            let version = try check({ fileManager.fileExists(atPath: folder + "/" + $0) },
                                    read: { try? String(contentsOfFile: folder + "/" + $0, encoding: .utf8) },
                                    place: "The kit folder in Settings")
            return KitInfo(source: .folder(folder), version: version)
        }
        guard let pinned else { throw .kit("The app's bundled hashtag kit is missing. Reinstall sangaku.") }
        let version = try check({ pinned.contents($0) != nil }, read: pinned.contents, place: "The bundled hashtag kit")
        guard version == pinned.version else { throw .kit("The bundled hashtag kit's VERSION does not match its pin.") }
        return KitInfo(source: .bundled(commit: pinned.commit), version: version)
    }

    /// The kit's files are there, its `main.tex` is the one the app patches, and its `VERSION` is a version.
    private static func check(_ exists: (String) -> Bool, read: (String) -> String?,
                              place: String) throws(ExportError) -> String {
        let missing = required.filter { !exists($0) }
        guard missing.isEmpty else { throw .kit(place + " is not a hashtag kit: it lacks " + Prose.list(missing) + ".") }
        let lines = (read("template/manuscript/main.tex") ?? "").components(separatedBy: "\n")
        guard lines.contains(where: { $0.hasPrefix("\\title{\\bfseries ") }), lines.contains("\\input{ch1-setting}") else {
            throw .kit(place + "'s main.tex is not the one this version of the app expects.")
        }
        let version = (read("VERSION") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.count <= 40, version.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw .kit(place + "'s VERSION file is not a version.")
        }
        return version
    }

    /// Puts what `kit.py new` reads into `destination` in the run folder: the bundled files, or a copy of the chosen
    /// folder, so the run never reads the person's folders and a kit edited mid-export cannot change it.
    @concurrent
    static func install(_ kit: KitInfo, to destination: String) async throws(ExportError) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: destination, withIntermediateDirectories: true)
            switch kit.source {
            case .bundled:
                guard let pinned = PinnedKit.bundled else { throw ExportError.kit("The app's bundled hashtag kit is missing.") }
                for file in pinned.files {
                    let target = URL(fileURLWithPath: destination + "/" + file.path)
                    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(file.contents.utf8).write(to: target)
                    if file.executable { try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
                }
            case .folder(let folder):
                for name in ["kit.py", "VERSION", "htag_paper.cls", "htag.sty", "template"] {
                    try manager.copyItem(atPath: folder + "/" + name, toPath: destination + "/" + name)
                }
                for junk in ["template/.build", "template/__pycache__"] {
                    try? manager.removeItem(atPath: destination + "/" + junk)
                }
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw .files("the hashtag kit could not be copied: " + error.localizedDescription)
        }
    }
}

/// The folder an export writes into: its state, the files the app owns in it, staging an earlier export for a
/// rebuild, and writing the result.
nonisolated enum ExportFolder {
    /// The build products `build.sh` leaves, never copied into the person's folder (`main.pdf` aside).
    static let buildProducts: Set<String> = ["aux", "log", "out", "toc", "fls", "fdb_latexmk", "bbl", "blg"]
    static let buildFiles: Set<String> = ["bibtex.out", "build.log", "htag-index.md", ".DS_Store"]

    static func state(_ folder: String, kind: ExportKind, problem: UUID,
                      fileManager: FileManager = .default) -> ExportFolderState {
        var isDirectory: ObjCBool = false
        guard folder.hasPrefix("/"), fileManager.fileExists(atPath: folder, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .refused("Choose an existing folder to export into.") }
        guard SandboxGrants.isSafe(folder) else {
            return .refused("The folder's path holds a character the sandbox cannot grant (\" \\ ( or )). Choose another folder.")
        }
        let entries = ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).filter { $0 != ".DS_Store" }
        if Set(entries).isSubset(of: [".git"]) { return .empty }
        guard let data = fileManager.contents(atPath: folder + "/" + ExportManifest.fileName),
              let manifest = try? JSONDecoder().decode(ExportManifest.self, from: data) else {
            return .refused("The folder holds other files. Choose an empty folder, or one this problem was exported to.")
        }
        guard manifest.problem == problem else { return .refused("The folder holds an export of another problem.") }
        guard manifest.kind == kind else {
            return .refused("The folder holds a \(manifest.kind.title) export of this problem, not a \(kind.title).")
        }
        if kind == .hashtag {
            let preamble = (try? String(contentsOfFile: folder + "/manuscript/preamble.tex", encoding: .utf8)) ?? ""
            guard preamble.components(separatedBy: "\n").contains("\\htagsalt{" + HashtagWriter.salt(problem) + "}") else {
                return .refused("The manuscript's salt is not this problem's, so every tag would change. Nothing is written.")
            }
            guard fileManager.fileExists(atPath: folder + "/.kit-manifest") else {
                return .refused("The manuscript's .kit-manifest is missing, so the kit's build cannot check it.")
            }
        }
        return .earlierExport
    }

    /// The source files the app writes, which git must show committed before an export replaces them. The tag
    /// registry and the PDFs are left out: the registry is checked to only grow, and a PDF is rebuilt from the sources.
    static func ownedPaths(_ plan: ExportPlan) -> [String] {
        var paths = plan.files.map(\.path)
        if plan.request.kind == .hashtag { paths += HashtagWriter.patchedFiles }
        return (paths + [ExportManifest.fileName]).sorted()
    }

    /// Every file an export may replace in the folder: the owned files, the registry and the PDFs.
    static func replacedPaths(_ plan: ExportPlan) -> [String] {
        switch plan.request.kind {
        case .hashtag: ownedPaths(plan) + ["manuscript/htag-registry.tex", "manuscript/main.pdf"]
        case .latex: ownedPaths(plan) + [ExportService.latexBaseName(plan) + ".pdf"]
        case .leanProject: ownedPaths(plan)
        }
    }

    /// Each path's SHA-256, or "absent": taken when an export starts and again just before it writes.
    @concurrent
    static func fingerprint(_ folder: String, paths: [String]) async -> [String: String] {
        Dictionary(uniqueKeysWithValues: paths.map { path in
            (path, FileManager.default.contents(atPath: folder + "/" + path)
                .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "absent")
        })
    }

    /// The folder of the git repository holding `folder`, or nil.
    static func repositoryRoot(of folder: String, fileManager: FileManager = .default) -> String? {
        var current = folder
        while current.count > 1 {
            if fileManager.fileExists(atPath: current + "/.git") { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The paths `git status --porcelain=v1 -z` lists: changed, staged, untracked or ignored.
    static func uncommitted(_ output: String) -> [String] {
        var paths: [String] = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            // A rename or copy is followed by its old path.
            if status.contains("R") || status.contains("C") { _ = entries.popFirst() }
        }
        return paths
    }

    /// Copies an earlier export's project for a rebuild: everything but `.git` and build products.
    @concurrent
    static func stage(_ folder: String, to project: String, limit: Int = 200 << 20) async throws(ExportError) {
        let tooLarge = ExportError.files("the folder holds more than \(limit >> 20) MB")
        let manager = FileManager.default
        guard let walker = manager.enumerator(atPath: folder) else { throw .files("the folder cannot be read") }
        var total = 0
        do {
            try manager.createDirectory(atPath: project, withIntermediateDirectories: true)
            while let relative = walker.nextObject() as? String {
                if relative == ".git" || relative.hasPrefix(".git/") { walker.skipDescendants(); continue }
                let source = folder + "/" + relative
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: source, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    try manager.createDirectory(atPath: project + "/" + relative, withIntermediateDirectories: true)
                } else if !isBuildProduct(relative) {
                    total += (try manager.attributesOfItem(atPath: source)[.size] as? Int) ?? 0
                    guard total <= limit else { throw tooLarge }
                    try manager.copyItem(atPath: source, toPath: project + "/" + relative)
                }
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw .files(error.localizedDescription)
        }
    }

    static func isBuildProduct(_ relative: String) -> Bool {
        let name = (relative as NSString).lastPathComponent
        return buildFiles.contains(name) || buildProducts.contains((name as NSString).pathExtension)
            || relative.contains("__pycache__") || relative.hasSuffix(".synctex.gz")
    }

    /// The files to copy from the run folder's project into the person's folder: on a first export the whole project
    /// but build products; later only what the app owns, the tag registry and the PDF. Frozen files and the kit's
    /// manifest are never copied back.
    static func installSet(project: String, plan: ExportPlan, first: Bool,
                           fileManager: FileManager = .default) -> [String] {
        guard first else {
            return ownedPaths(plan).filter { $0 != ExportManifest.fileName }
                + ["manuscript/htag-registry.tex", "manuscript/main.pdf"].filter { fileManager.fileExists(atPath: project + "/" + $0) }
        }
        var paths: [String] = []
        let walker = fileManager.enumerator(atPath: project)
        while let relative = walker?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: project + "/" + relative, isDirectory: &isDirectory), !isDirectory.boolValue,
               !isBuildProduct(relative) {
                paths.append(relative)
            }
        }
        return paths.sorted()
    }

    /// The tag registry may only grow: the same salt, and every earlier entry kept as it was.
    static func registryGrows(old: String, new: String) -> Bool {
        func lines(_ text: String, _ prefix: String) -> Set<String> {
            Set(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix(prefix) })
        }
        guard !old.isEmpty else { return true }
        return lines(old, "\\htagregistrysalt{") == lines(new, "\\htagregistrysalt{")
            && lines(old, "\\htagentry{").isSubset(of: lines(new, "\\htagentry{"))
    }

    /// Copies `staged` from `source` into `folder`, then writes `files`, each replaced whole, in order (the manifest
    /// comes last). If a write fails, the files this call created are removed again; a file it replaced stays replaced.
    @concurrent
    static func install(_ staged: [String], from source: String, files: [ExportFile],
                        into folder: String) async throws(ExportError) {
        let manager = FileManager.default
        var created: [String] = []
        func put(_ data: Data, at relative: String) throws {
            let target = URL(fileURLWithPath: folder + "/" + relative)
            let existed = manager.fileExists(atPath: target.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            if !existed { created.append(target.path) }
            if relative.hasSuffix(".sh") || relative.hasSuffix(".py") {
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
        }
        do {
            for relative in staged { try put(try Data(contentsOf: URL(fileURLWithPath: source + "/" + relative)), at: relative) }
            for file in files { try put(Data(file.contents.utf8), at: file.path) }
        } catch {
            for path in created.reversed() { try? manager.removeItem(atPath: path) }
            throw .files(error.localizedDescription + ". The files this export had created were removed.")
        }
    }
}
