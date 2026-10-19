import CryptoKit
import Foundation

/// One user macro from the notation registry.
nonisolated struct MacroDefinition: Hashable, Sendable, Codable {
    nonisolated enum Kind: String, Hashable, Sendable, Codable {
        /// `\newcommand` and its relatives.
        case command
        /// `\DeclareMathOperator`.
        case operatorName
        /// `\DeclareMathOperator*` (limits below and above in display style).
        case operatorNameWithLimits
    }

    /// Without the backslash.
    var name: String
    var arity: Int
    /// The body for a command; the operator's text for the operator kinds.
    var body: String
    var kind: Kind

    /// What the macro expands to, with `#1…#n` placeholders.
    var replacement: String {
        switch kind {
        case .command: body
        case .operatorName: "\\operatorname{\(body)}"
        case .operatorNameWithLimits: "\\operatorname*{\(body)}"
        }
    }

    /// The canonical preamble line stored in `NotationEntry.macroDefinition`.
    var canonicalSource: String {
        switch kind {
        case .command:
            arity > 0 ? "\\newcommand{\\\(name)}[\(arity)]{\(body)}" : "\\newcommand{\\\(name)}{\(body)}"
        case .operatorName:
            "\\DeclareMathOperator{\\\(name)}{\(body)}"
        case .operatorNameWithLimits:
            "\\DeclareMathOperator*{\\\(name)}{\(body)}"
        }
    }
}

nonisolated struct MacroError: Error, Hashable, Sendable {
    var message: String
}

/// The macros in force for a problem. Applied to every formula before any renderer sees it.
nonisolated struct MacroSet: Hashable, Sendable {
    /// Keyed by name. A later definition of the same name replaces an earlier one, as `\renewcommand` would.
    let definitions: [String: MacroDefinition]
    /// SHA-256 of the sorted canonical sources: part of every cache key, so a change re-renders.
    let fingerprint: String

    static let empty = MacroSet([])

    /// Limits that turn runaway definitions (`\newcommand{\a}{\a\a}`) into an error instead of a hang.
    static let maxExpansions = 2_000
    static let maxTokens = 20_000

    init(_ definitions: [MacroDefinition]) {
        var byName: [String: MacroDefinition] = [:]
        for definition in definitions { byName[definition.name] = definition }
        self.definitions = byName
        let canonical = byName.values.map(\.canonicalSource).sorted().joined(separator: "\n")
        fingerprint = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var isEmpty: Bool { definitions.isEmpty }

    /// Expands every user macro in `tex`, including macros produced by other macros.
    func expand(_ tex: String) -> Result<String, MacroError> {
        guard !definitions.isEmpty else { return .success(tex) }
        var tokens = TeXLexer.tokens(tex)
        var expansions = 0
        var i = 0
        while i < tokens.count {
            guard case .command(let name) = tokens[i], let definition = definitions[name] else {
                i += 1
                continue
            }
            var arguments: [[TeXToken]] = []
            var end = i + 1
            for n in 0..<definition.arity {
                guard let argument = tokens.argument(at: end) else {
                    return .failure(MacroError(message: "\\\(name) expects \(definition.arity) argument(s) but argument \(n + 1) is missing"))
                }
                arguments.append(argument.contents)
                end = argument.end
            }
            expansions += 1
            if expansions > Self.maxExpansions {
                return .failure(MacroError(message: "Macro expansion did not terminate (\\\(name) keeps expanding)"))
            }
            let replacement = Self.substitute(arguments, into: TeXLexer.tokens(definition.replacement))
            tokens.replaceSubrange(i..<end, with: replacement)
            if tokens.count > Self.maxTokens {
                return .failure(MacroError(message: "Macro expansion of \\\(name) grew too long"))
            }
            // Rescan from `i`: the replacement may itself contain macros.
        }
        return .success(TeXLexer.string(tokens))
    }

    /// Replaces `#1…#9` in a body, in a single pass, so substituted text is never rescanned for `#`.
    private static func substitute(_ arguments: [[TeXToken]], into body: [TeXToken]) -> [TeXToken] {
        var out: [TeXToken] = []
        var i = 0
        while i < body.count {
            if case .char("#") = body[i], i + 1 < body.count, case .char(let d) = body[i + 1],
               let n = d.wholeNumberValue, n >= 1, n <= arguments.count {
                out += arguments[n - 1]
                i += 2
            } else {
                out.append(body[i])
                i += 1
            }
        }
        return out
    }
}
