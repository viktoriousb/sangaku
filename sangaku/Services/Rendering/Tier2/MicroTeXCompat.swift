import Foundation

/// TeX-faithful input rewrites for constructs MicroTeX treats differently from amsmath. They work on tokens,
/// respect nested braces, and leave text arguments (`\text{and/or}`) alone.
nonisolated enum MicroTeXCompat {
    /// Commands whose argument is text, copied verbatim.
    private static let textCommands: Set<String> = ["text", "textrm", "textit", "textbf", "mathrm", "mbox", "operatorname"]

    static func rewrite(_ latex: String) -> String {
        TeXLexer.string(rewrite(TeXLexer.tokens(latex)))
    }

    static func rewrite(_ tokens: [TeXToken]) -> [TeXToken] {
        var out: [TeXToken] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            switch token {
            case .command("pmod"):
                // amsmath, inline: \mkern8mu(\operator@font mod\mkern6mu #1); MicroTeX adds far more space.
                guard let argument = tokens.argument(at: i + 1) else { out.append(token); i += 1; continue }
                out += TeXLexer.tokens(#"\,\;(\mathrm{mod}\,\,"#) + rewrite(argument.contents) + [.char(")")]
                i = argument.end
            case .command("bmod"):
                out += TeXLexer.tokens(#"\mathbin{\mathrm{mod}}"#)
                i += 1
            case .command("operatorname"):
                let next = tokens.skippingSpaces(from: i + 1)
                if next < tokens.count, tokens[next] == .char("*"), let argument = tokens.argument(at: next + 1) {
                    // MicroTeX misreads \operatorname* as \operatorname followed by "*".
                    out += [.command("mathop"), .open, .command("mathrm"), .open] + argument.contents
                        + [.close, .close, .command("limits")]
                    i = argument.end
                } else {
                    out.append(token)
                    i += 1
                    if let argument = tokens.argument(at: i) {
                        out += [.open] + argument.contents + [.close]
                        i = argument.end
                    }
                }
            case .command(let name) where textCommands.contains(name):
                out.append(token)
                i += 1
                if let argument = tokens.argument(at: i) {
                    out += [.open] + argument.contents + [.close]
                    i = argument.end
                }
            case .char("/"):
                // TeX's / is an ordinary symbol; MicroTeX spaces it like a binary operator.
                out += [.open, .char("/"), .close]
                i += 1
            default:
                out.append(token)
                i += 1
            }
        }
        return out
    }
}
