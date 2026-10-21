import Foundation

/// Which sandbox a job runs in. `offline` is for everything a model or a person wrote; `fetch` only for fetching Mathlib.
nonisolated enum SandboxKind: String, Hashable, Sendable {
    case offline, fetch

    var resourceName: String { "sandbox-" + rawValue }
}

/// The paths a job may use beyond its sandbox's fixed rules: read only, or read and write. Nothing in the home folder is
/// readable unless granted here, since the fixed rules deny everything they do not name. Every path is absolute and
/// free of characters that could end a profile string early, or the job is refused.
nonisolated struct SandboxGrants: Hashable, Sendable {
    var readable: [String] = []
    var writable: [String] = []

    /// A path the profile can name safely: absolute, with no quote, backslash, parenthesis or control character.
    static func isSafe(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("..")
            && path.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !"\"\\()".unicodeScalars.contains($0) }
    }

    var allSafe: Bool { (readable + writable).allSatisfy(Self.isSafe) }
}

/// Renders a job's sandbox profile: the fixed rules from the app bundle, then the job's grants. SBPL takes the last
/// matching rule, so the grants come last and can only widen what the fixed rules deny to the paths named.
nonisolated enum SandboxProfile {
    nonisolated enum Failure: Error, Hashable, Sendable {
        case missingProfile(String)
        case unsafePath

        var message: String {
            switch self {
            case .missingProfile(let name): "The sandbox profile \(name).sb is missing from the app."
            case .unsafePath: "A path for the sandbox contains characters the profile cannot hold."
            }
        }
    }

    /// The fixed rules, from the app bundle.
    static func bundled(_ kind: SandboxKind) -> String? {
        Bundle.main.url(forResource: kind.resourceName, withExtension: "sb").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static func render(_ kind: SandboxKind, grants: SandboxGrants,
                       source: (SandboxKind) -> String? = bundled) throws(Failure) -> String {
        guard let base = source(kind) else { throw .missingProfile(kind.resourceName) }
        guard grants.allSafe else { throw .unsafePath }
        var lines = [base, ";; Granted to this job by the app."]
        let readable = grants.readable + grants.writable
        if !readable.isEmpty {
            lines.append("(allow file-read* " + readable.map { "(subpath \"\($0)\")" }.joined(separator: " ") + ")")
        }
        if !grants.writable.isEmpty {
            lines.append("(allow file-write* " + grants.writable.map { "(subpath \"\($0)\")" }.joined(separator: " ") + ")")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
