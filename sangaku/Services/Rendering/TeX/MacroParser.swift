import Foundation

/// A definition the parser saw but did not import, with the reason. Never dropped silently.
nonisolated struct SkippedDefinition: Hashable, Sendable {
    var line: Int
    var text: String
    var reason: String
}

nonisolated struct MacroParseResult: Hashable, Sendable {
    var definitions: [MacroDefinition] = []
    var skipped: [SkippedDefinition] = []
}

/// Reads macro definitions from a LaTeX preamble (or a single definition line).
///
/// Supported: `\newcommand`, `\renewcommand`, `\providecommand` (each with an optional `*`, a braced or bare
/// name and an argument count) and `\DeclareMathOperator` (with an optional `*`). `%` comments are ignored.
/// Everything else that defines something (`\def`, `\let`, default arguments, environments, xparse) is reported
/// in `skipped`. Lines that define nothing (`\usepackage`, text) are ignored.
nonisolated enum MacroParser {
    private static let reportedButUnsupported: [String: String] = [
        "def": "\\def is not supported; use \\newcommand",
        "gdef": "\\gdef is not supported; use \\newcommand",
        "edef": "\\edef is not supported; use \\newcommand",
        "let": "\\let is not supported; use \\newcommand",
        "newenvironment": "environments are not supported",
        "renewenvironment": "environments are not supported",
        "DeclarePairedDelimiter": "\\DeclarePairedDelimiter is not supported; use \\newcommand",
        "NewDocumentCommand": "xparse commands are not supported; use \\newcommand",
        "RenewDocumentCommand": "xparse commands are not supported; use \\newcommand",
        "DeclareDocumentCommand": "xparse commands are not supported; use \\newcommand",
        "ProvideDocumentCommand": "xparse commands are not supported; use \\newcommand",
        "DeclareRobustCommand": "\\DeclareRobustCommand is not supported; use \\newcommand",
        "newcommandx": "\\newcommandx is not supported; use \\newcommand",
        "renewcommandx": "\\renewcommandx is not supported; use \\newcommand",
        "DeclareMathSymbol": "\\DeclareMathSymbol is not supported",
        "DeclareMathAlphabet": "\\DeclareMathAlphabet is not supported",
        "mathchardef": "\\mathchardef is not supported",
        "chardef": "\\chardef is not supported",
    ]

    /// Commands LaTeX already defines, which `\providecommand` leaves alone.
    static func isBuiltIn(_ name: String) -> Bool {
        TypographicMath.symbols[name] != nil || TypographicMath.greek[name] != nil
            || TypographicMath.operatorNames.contains(name) || TeXValidator.arity[name] != nil
            || ["sum", "prod", "int", "lim", "infty", "left", "right", "begin", "end", "limits", "mathop",
                "mathbin", "mathrel", "displaystyle", "textstyle", "quad", "qquad", "cdot", "ldots"].contains(name)
    }

    static func parse(_ source: String) -> MacroParseResult {
        let located = TeXLexer.tokensWithLines(source, stripComments: true)
        let tokens = located.map(\.token)
        let lines = TeXLexer.normalizingNewlines(source).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func text(ofLine line: Int) -> String {
            line - 1 < lines.count ? lines[line - 1].trimmingCharacters(in: .whitespaces) : ""
        }

        var result = MacroParseResult()
        var provided: Set<String> = []
        var i = 0
        while i < tokens.count {
            guard case .command(let command) = tokens[i] else { i += 1; continue }
            let line = located[i].line
            switch command {
            case "newcommand", "renewcommand", "providecommand":
                switch parseNewCommand(tokens, from: i + 1) {
                case .success(let (definition, end)):
                    if command == "providecommand" && isBuiltIn(definition.name) {
                        result.skipped.append(SkippedDefinition(
                            line: line, text: text(ofLine: line),
                            reason: "\\\(definition.name) is already defined by LaTeX, so \\providecommand does nothing"))
                    } else if command == "providecommand" && provided.contains(definition.name) {
                        // \providecommand never replaces an existing definition.
                    } else {
                        result.definitions.append(definition)
                        provided.insert(definition.name)
                    }
                    i = end
                case .failure(let error):
                    result.skipped.append(SkippedDefinition(line: line, text: text(ofLine: line), reason: error.message))
                    i += 1
                }
            case "DeclareMathOperator":
                switch parseOperator(tokens, from: i + 1) {
                case .success(let (definition, end)):
                    result.definitions.append(definition)
                    provided.insert(definition.name)
                    i = end
                case .failure(let error):
                    result.skipped.append(SkippedDefinition(line: line, text: text(ofLine: line), reason: error.message))
                    i += 1
                }
            default:
                if let reason = reportedButUnsupported[command] {
                    result.skipped.append(SkippedDefinition(line: line, text: text(ofLine: line), reason: reason))
                }
                i += 1
            }
        }
        return result
    }

    /// Reads `{\name}` or `\name`.
    private static func name(_ tokens: [TeXToken], at index: Int) -> (String, Int)? {
        let i = tokens.skippingSpaces(from: index)
        guard i < tokens.count else { return nil }
        if case .command(let name) = tokens[i] { return (name, i + 1) }
        if let group = tokens.group(at: i) {
            let inner = group.contents.filter { if case .space = $0 { false } else { true } }
            if inner.count == 1, case .command(let name) = inner[0] { return (name, group.end) }
        }
        return nil
    }

    private static func parseNewCommand(_ tokens: [TeXToken], from start: Int) -> Result<(MacroDefinition, Int), MacroError> {
        var i = tokens.skippingSpaces(from: start)
        if i < tokens.count, tokens[i] == .char("*") { i += 1 }
        guard let (name, afterName) = name(tokens, at: i) else {
            return .failure(MacroError(message: "malformed definition: missing \\name"))
        }
        i = tokens.skippingSpaces(from: afterName)
        var arity = 0
        if i < tokens.count, tokens[i] == .char("[") {
            var digits = ""
            var j = i + 1
            while j < tokens.count, case .char(let c) = tokens[j], c != "]" { digits.append(c); j += 1 }
            guard j < tokens.count, let n = Int(digits.trimmingCharacters(in: .whitespaces)), (0...9).contains(n) else {
                return .failure(MacroError(message: "malformed argument count for \\\(name)"))
            }
            arity = n
            i = tokens.skippingSpaces(from: j + 1)
            if i < tokens.count, tokens[i] == .char("[") {
                return .failure(MacroError(message: "optional-argument defaults are not supported (\\\(name))"))
            }
        }
        guard let body = tokens.group(at: i) else {
            return .failure(MacroError(message: "malformed definition of \\\(name): missing {body}"))
        }
        let definition = MacroDefinition(name: name, arity: arity, body: TeXLexer.string(body.contents), kind: .command)
        return .success((definition, body.end))
    }

    private static func parseOperator(_ tokens: [TeXToken], from start: Int) -> Result<(MacroDefinition, Int), MacroError> {
        var i = tokens.skippingSpaces(from: start)
        var limits = false
        if i < tokens.count, tokens[i] == .char("*") { limits = true; i += 1 }
        guard let (name, afterName) = name(tokens, at: i) else {
            return .failure(MacroError(message: "malformed \\DeclareMathOperator: missing \\name"))
        }
        guard let text = tokens.group(at: tokens.skippingSpaces(from: afterName)) else {
            return .failure(MacroError(message: "malformed \\DeclareMathOperator for \\\(name): missing {text}"))
        }
        let definition = MacroDefinition(name: name, arity: 0, body: TeXLexer.string(text.contents),
                                         kind: limits ? .operatorNameWithLimits : .operatorName)
        return .success((definition, text.end))
    }
}
