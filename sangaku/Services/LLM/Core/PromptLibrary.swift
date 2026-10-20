import Foundation

/// A role's prompt, with the version recorded on every request that uses it.
nonisolated struct RolePrompt: Hashable, Sendable {
    var role: SlotRole
    var version: String
    var text: String
    /// The prompt file's name: one role can have several prompts (a prover's prose replies and its attempts).
    var name: String

    init(role: SlotRole, version: String, text: String, name: String? = nil) {
        self.role = role
        self.version = version
        self.text = text
        self.name = name ?? role.rawValue
    }

    /// Stored as `RequestRecord.promptVersion`, e.g. "prover@1" or "prover-attempt@2".
    var versionTag: String { "\(name)@\(version)" }
}

/// Loads role prompts from `Resources/Prompts/<role>.md`. A prompt file starts with `version: <n>`, then a
/// line `---`, then the prompt text. Resources are flattened into the bundle, so names must be unique.
nonisolated struct PromptLibrary: Sendable {
    private let source: @Sendable (String) -> String?

    init(source: @escaping @Sendable (String) -> String?) {
        self.source = source
    }

    static let bundled = PromptLibrary { name in
        guard let url = Bundle.main.url(forResource: name, withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The prompt for a role, or nil when the file is missing or malformed. A request is never sent without
    /// its role prompt. A prover writing a structured attempt (`structured`) has its own prompt,
    /// `prover-attempt.md`; its prose replies keep `prover.md`.
    func prompt(for role: SlotRole, structured: Bool = false) -> RolePrompt? {
        let name = Self.fileName(role, structured: structured)
        return source(name).flatMap { Self.parse($0, role: role, name: name) }
    }

    /// A prompt by file name, for a purpose with a prompt of its own (the aligner, a referee's reply), used in `role`.
    func prompt(named name: String, role: SlotRole) -> RolePrompt? {
        source(name).flatMap { Self.parse($0, role: role, name: name) }
    }

    static func fileName(_ role: SlotRole, structured: Bool) -> String {
        role == .prover && structured ? "prover-attempt" : role.rawValue
    }

    static func parse(_ file: String, role: SlotRole, name: String? = nil) -> RolePrompt? {
        let lines = file.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3,
              let header = lines.first, header.hasPrefix("version:"),
              lines[1].trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        let version = header.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
        let text = lines.dropFirst(2).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, !text.isEmpty else { return nil }
        return RolePrompt(role: role, version: version, text: text, name: name)
    }
}
