import Foundation

/// Structural checks every formula passes before any renderer sees it. MicroTeX quietly repairs some broken
/// input (an unclosed `\frac{a`, a missing argument); repaired math is approximated math, so such input
/// becomes a source chip instead (invariant 16).
nonisolated enum TeXValidator {
    /// Commands and how many braced arguments they require.
    static let arity: [String: Int] = [
        "frac": 2, "dfrac": 2, "tfrac": 2, "cfrac": 2, "binom": 2, "dbinom": 2, "tbinom": 2, "genfrac": 6,
        "sqrt": 1, "overset": 2, "underset": 2, "stackrel": 2, "xrightarrow": 1, "xleftarrow": 1,
        "overline": 1, "underline": 1, "overbrace": 1, "underbrace": 1, "boxed": 1, "phantom": 1,
        "hat": 1, "widehat": 1, "tilde": 1, "widetilde": 1, "bar": 1, "vec": 1, "dot": 1, "ddot": 1,
        "check": 1, "breve": 1, "acute": 1, "grave": 1, "mathring": 1,
        "mathbb": 1, "mathcal": 1, "mathfrak": 1, "mathscr": 1, "mathrm": 1, "mathbf": 1, "mathit": 1,
        "mathsf": 1, "mathtt": 1, "boldsymbol": 1, "text": 1, "textrm": 1, "textit": 1, "textbf": 1,
        "mbox": 1, "operatorname": 1, "substack": 1, "pmod": 1, "color": 1, "textcolor": 2,
    ]

    /// Commands that define things. They belong in the notation registry: inside a formula they would change
    /// MicroTeX's global macro table and so the meaning of later formulas.
    static let definitions: Set<String> = [
        "newcommand", "renewcommand", "providecommand", "def", "gdef", "edef", "let", "DeclareMathOperator",
        "newenvironment", "renewenvironment", "DeclareRobustCommand", "NewDocumentCommand",
    ]

    /// nil if the formula is structurally sound, otherwise what is wrong.
    static func problem(in latex: String) -> String? {
        let tokens = TeXLexer.tokens(latex)
        // Braces first, so an unclosed group is reported as such rather than as a missing argument.
        var balance = 0
        for token in tokens {
            if token == .open { balance += 1 }
            if token == .close { balance -= 1; if balance < 0 { return "A closing brace has no opening brace" } }
        }
        if balance > 0 { return "An opening brace is never closed" }
        var depth = 0
        var leftRight = 0
        var environments: [String] = []
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case .open:
                depth += 1
            case .close:
                depth -= 1
                if depth < 0 { return "A closing brace has no opening brace" }
            case .command("left"):
                leftRight += 1
            case .command("right"):
                leftRight -= 1
                if leftRight < 0 { return "\\right has no matching \\left" }
            case .command("begin"), .command("end"):
                guard let name = tokens.argument(at: i + 1) else { return "\\begin or \\end without an environment name" }
                let environment = TeXLexer.string(name.contents)
                if tokens[i] == .command("begin") {
                    environments.append(environment)
                } else if environments.popLast() != environment {
                    return "\\end{\(environment)} does not match the open environment"
                }
            case .command(let name) where definitions.contains(name):
                return "Definitions such as \\\(name) belong in the notation registry, not in a formula"
            case .command(let name):
                if let required = arity[name] {
                    var end = i + 1
                    if name == "sqrt" { end = skipOptional(tokens, from: end) }
                    if name == "operatorname" || name == "xrightarrow" || name == "xleftarrow" {
                        let next = tokens.skippingSpaces(from: end)
                        if next < tokens.count, tokens[next] == .char("*") { end = next + 1 }
                        end = skipOptional(tokens, from: end)
                    }
                    for n in 0..<required {
                        guard let argument = tokens.argument(at: end) else {
                            return "\\\(name) is missing argument \(n + 1) of \(required)"
                        }
                        end = argument.end
                    }
                }
            default:
                break
            }
            i += 1
        }
        if depth > 0 { return "An opening brace is never closed" }
        if leftRight > 0 { return "\\left has no matching \\right" }
        if let open = environments.last { return "\\begin{\(open)} is never closed" }
        return nil
    }

    /// Skips an optional `[…]` argument.
    private static func skipOptional(_ tokens: [TeXToken], from index: Int) -> Int {
        let i = tokens.skippingSpaces(from: index)
        guard i < tokens.count, tokens[i] == .char("[") else { return index }
        var j = i + 1
        var depth = 0
        while j < tokens.count {
            switch tokens[j] {
            case .open: depth += 1
            case .close: depth -= 1
            case .char("]") where depth == 0: return j + 1
            default: break
            }
            j += 1
        }
        return index
    }
}
