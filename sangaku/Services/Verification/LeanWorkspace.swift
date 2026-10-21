import Foundation

/// The Lean and Mathlib release every workspace is pinned to. Checks run this toolchain's own `lean`, so elan never
/// decides which Lean runs, and never tries to download one inside the offline sandbox.
nonisolated enum LeanPin {
    static let toolchain = "leanprover/lean4:v4.35.0"
    static let mathlibRev = "v4.35.0"

    /// elan's folder name for a toolchain: `leanprover--lean4---v4.35.0`.
    static func folderName(_ toolchain: String) -> String {
        toolchain.replacingOccurrences(of: "/", with: "--").replacingOccurrences(of: ":", with: "---")
    }
}

/// What the app learned when it fetched Mathlib, kept in the workspace: where the toolchain's `lean` is and the path
/// Lean finds Mathlib on. A check needs nothing else from lake.
nonisolated struct LeanWorkspaceRecord: Codable, Hashable, Sendable {
    var environment: LeanEnvironment
    var lean: String
    var leanPath: [String]
    var fetchedAt: Date
}

/// Where the shared workspace stands.
nonisolated enum LeanWorkspaceState: Hashable, Sendable {
    case noFolder
    /// The folder holds files that are not a sangaku workspace: nothing is written there.
    case foreign
    case notFetched
    case ready(LeanWorkspaceRecord)
    case broken(String)

    var record: LeanWorkspaceRecord? {
        if case .ready(let record) = self { record } else { nil }
    }

    /// Why a check cannot run, in words; nil when it can.
    var refusal: String? {
        switch self {
        case .noFolder: "Choose a folder for the Lean workspace in Settings, then fetch Mathlib."
        case .foreign: "The Lean workspace folder holds other files. Choose an empty folder in Settings."
        case .notFetched: "Mathlib has not been fetched into the Lean workspace. Fetch it in Settings."
        case .broken(let reason): "The Lean workspace needs fetching again: \(reason)"
        case .ready: nil
        }
    }
}

/// The shared Lean workspace: its files, its state, and the steps of fetching Mathlib into it.
nonisolated struct LeanWorkspace: Hashable, Sendable {
    /// elan's own folder, where toolchains are installed.
    static var defaultElanHome: String { NSHomeDirectory() + "/.elan" }

    let root: String
    var elanHome: String = LeanWorkspace.defaultElanHome

    var recordPath: String { root + "/.sangaku/workspace.json" }
    var ownerMarker: String { root + "/.sangaku/owner" }
    /// Where fetching keeps Mathlib's downloaded files: inside the workspace, never the home folder's cache.
    var cacheHome: String { root + "/.sangaku/cache" }
    var toolchainRoot: String { elanHome + "/toolchains/" + LeanPin.folderName(LeanPin.toolchain) }
    var lean: String { toolchainRoot + "/bin/lean" }
    var lake: String { toolchainRoot + "/bin/lake" }

    /// The package file: Mathlib at the pinned release, nothing else, no code (a `lakefile.toml`, not a `.lean`).
    static let lakefile = """
    name = "sangaku-workspace"
    defaultTargets = []

    [[require]]
    name = "mathlib"
    git = "https://github.com/leanprover-community/mathlib4.git"
    rev = "\(LeanPin.mathlibRev)"
    """

    /// Reads the workspace's state from its files.
    func state(fileManager: FileManager = .default) -> LeanWorkspaceState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { return .noFolder }
        let contents = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
        let ours = fileManager.fileExists(atPath: ownerMarker)
        // A folder that is not ours is used only if it is empty: hidden files (a `.git`, say) are someone's too.
        if !ours { return contents.allSatisfy { $0 == ".DS_Store" } ? .notFetched : .foreign }
        guard let data = fileManager.contents(atPath: recordPath),
              let record = JSONColumn.decode(LeanWorkspaceRecord.self, from: data) else { return .notFetched }
        guard record.environment.toolchain == LeanPin.toolchain, record.environment.mathlibRev == LeanPin.mathlibRev else {
            return .broken("it was fetched for another release (\(record.environment.mathlibRev)).")
        }
        // A check runs the pinned toolchain's own `lean` and reads only Lean's path, so both must be where the fetch
        // put them.
        guard record.lean == lean, fileManager.isExecutableFile(atPath: lean) else {
            return .broken("its Lean toolchain is missing.")
        }
        guard record.leanPath.allSatisfy({ $0.hasPrefix(root + "/") || $0.hasPrefix(toolchainRoot + "/") }) else {
            return .broken("Lean's path leaves the workspace.")
        }
        guard !record.leanPath.isEmpty, record.leanPath.allSatisfy({ fileManager.fileExists(atPath: $0) }),
              record.leanPath.contains(where: { fileManager.fileExists(atPath: $0 + "/Mathlib.olean") }) else {
            return .broken("Mathlib's compiled files are missing.")
        }
        return .ready(record)
    }

    /// What a check runs and reads.
    func checkSetup(_ record: LeanWorkspaceRecord) -> LeanCheckSetup {
        LeanCheckSetup(toolchainRoot: toolchainRoot, lean: lean, leanPath: record.leanPath)
    }

    var fetchSetup: LeanFetchSetup {
        LeanFetchSetup(workspace: root, elanHome: elanHome, cacheHome: cacheHome, home: NSHomeDirectory(),
                       toolchainBin: toolchainRoot + "/bin")
    }

    /// Writes the package files and marks the folder as the app's. Refuses a folder holding anything else.
    func prepare(fileManager: FileManager = .default) throws(VerificationError) {
        switch state(fileManager: fileManager) {
        case .foreign: throw .workspace(LeanWorkspaceState.foreign.refusal ?? "")
        case .noFolder:
            do { try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true) } catch {
                throw .workspace("The workspace folder could not be created: \(error.localizedDescription)")
            }
        case .notFetched, .ready, .broken: break
        }
        do {
            try fileManager.createDirectory(atPath: cacheHome, withIntermediateDirectories: true)
            try Data("sangaku Lean workspace\n".utf8).write(to: URL(fileURLWithPath: ownerMarker))
            try Data((Self.lakefile + "\n").utf8).write(to: URL(fileURLWithPath: root + "/lakefile.toml"))
            try Data((LeanPin.toolchain + "\n").utf8).write(to: URL(fileURLWithPath: root + "/lean-toolchain"))
            try Data(".lake/\n.sangaku/cache/\n".utf8).write(to: URL(fileURLWithPath: root + "/.gitignore"))
        } catch {
            throw .workspace("The workspace files could not be written: \(error.localizedDescription)")
        }
    }

    /// Lean's version from `lean --version` ("Lean (version 4.35.0, arm64-apple-darwin, …)").
    static func leanVersion(from output: String) -> String? {
        guard let range = output.range(of: "version ") else { return nil }
        let version = output[range.upperBound...].prefix { $0 != "," && $0 != ")" && !$0.isWhitespace }
        return version.isEmpty ? nil : String(version)
    }

    /// The `LEAN_PATH` that `lake env printenv LEAN_PATH` printed.
    static func leanPath(from output: String) -> [String] {
        output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    /// Mathlib's revision from `lake-manifest.json`.
    func mathlibRevision(fileManager: FileManager = .default) -> String? {
        struct Manifest: Decodable {
            struct Package: Decodable {
                var name: String
                var rev: String?
                var inputRev: String?
            }

            var packages: [Package]
        }
        guard let data = fileManager.contents(atPath: root + "/lake-manifest.json"),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let mathlib = manifest.packages.first(where: { $0.name == "mathlib" }) else { return nil }
        return mathlib.inputRev ?? mathlib.rev
    }

    /// The toolchain Mathlib itself asks for, once it is fetched.
    func mathlibToolchain(fileManager: FileManager = .default) -> String? {
        fileManager.contents(atPath: root + "/.lake/packages/mathlib/lean-toolchain")
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
