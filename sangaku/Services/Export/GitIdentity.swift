import Foundation

/// The name and email the person's git commits carry, read from their git configuration: what the app's commits of an
/// export are made with, so they look like the person's own. Read as text, not by running git, and passed only to the
/// sandboxed git that commits.
nonisolated struct GitIdentity: Hashable, Sendable {
    var name: String
    var email: String

    /// From `~/.config/git/config`, then `~/.gitconfig`, then the repository's own `.git/config`: a later file wins,
    /// as in git. Nil when no file sets both.
    static func read(home: String, repository: String?) -> GitIdentity? {
        var name: String?
        var email: String?
        let files = [home + "/.config/git/config", home + "/.gitconfig"] + (repository.map { [$0 + "/.git/config"] } ?? [])
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let values = userValues(text)
            name = values.name ?? name
            email = values.email ?? email
        }
        guard let name, let email, valid(name), valid(email) else { return nil }
        return GitIdentity(name: name, email: email)
    }

    /// `user.name` and `user.email` in one config file: the last of each in a `[user]` section.
    static func userValues(_ text: String) -> (name: String?, email: String?) {
        var section = ""
        var name: String?
        var email: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // `[user "work"]` is a subsection, not `user`.
                section = line.dropFirst().prefix { $0 != "]" }.trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard section == "user", let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = Self.value(String(line[line.index(after: equals)...]))
            if key == "name" { name = value }
            if key == "email" { email = value }
        }
        return (name, email)
    }

    /// A value as git reads it: quotes removed, and a comment (`#` or `;`) outside quotes dropped.
    private static func value(_ text: String) -> String {
        var out = ""
        var quoted = false
        var escaped = false
        for character in text {
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if !quoted, character == "#" || character == ";" {
                break
            } else {
                out.append(character)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 && CodeText.hiddenScalar(in: value) == nil && !value.contains("\n")
    }
}
