// User macros from a preamble. KaTeX takes them natively; SwiftMath needs them expanded first.

struct MacroSet {
    struct Macro {
        let arity: Int
        let body: String
    }

    private(set) var macros: [String: Macro] = [:]

    init(preamble: String) {
        let chars = Array(preamble)
        var i = 0
        while i < chars.count {
            if Self.matches("\\newcommand", chars, i) || Self.matches("\\renewcommand", chars, i) {
                i += Self.matches("\\newcommand", chars, i) ? 11 : 13
                guard let (nameGroup, afterName) = Self.group(chars, i) else { break }
                i = afterName
                var arity = 0
                Self.skipSpaces(chars, &i)
                if i < chars.count, chars[i] == "[" {
                    var j = i + 1
                    var digits = ""
                    while j < chars.count, chars[j] != "]" { digits.append(chars[j]); j += 1 }
                    arity = Int(digits) ?? 0
                    i = j + 1
                }
                guard let (body, afterBody) = Self.group(chars, i) else { break }
                i = afterBody
                macros[Self.stripBackslash(nameGroup)] = Macro(arity: arity, body: body)
            } else if Self.matches("\\DeclareMathOperator", chars, i) {
                i += 20
                var starred = false
                if i < chars.count, chars[i] == "*" { starred = true; i += 1 }
                guard let (nameGroup, afterName) = Self.group(chars, i),
                      let (text, afterText) = Self.group(chars, afterName) else { break }
                i = afterText
                macros[Self.stripBackslash(nameGroup)] = Macro(
                    arity: 0, body: starred ? "\\operatorname*{\(text)}" : "\\operatorname{\(text)}")
            } else {
                i += 1
            }
        }
    }

    /// Macros in the form KaTeX's `macros` option expects.
    var katexMacros: [String: String] {
        Dictionary(uniqueKeysWithValues: macros.map { ("\\" + $0.key, $0.value.body) })
    }

    /// Expands user macros. With `swiftMathFallbacks`, also rewrites constructs SwiftMath lacks.
    func expand(_ tex: String, swiftMathFallbacks: Bool = false) -> String {
        var s = tex
        for _ in 0..<32 {
            let next = expandOnce(s)
            if next == s { break }
            s = next
        }
        if swiftMathFallbacks {
            s = rewriteCommand(s, "\\operatorname*", to: "\\mathrm")
            s = rewriteCommand(s, "\\operatorname", to: "\\mathrm")
        }
        return s
    }

    private func expandOnce(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\", i + 1 < chars.count, chars[i + 1].isLetter else {
                out.append(chars[i]); i += 1; continue
            }
            var j = i + 1
            var name = ""
            while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
            guard let macro = macros[name] else {
                out.append(contentsOf: chars[i..<j]); i = j; continue
            }
            var args: [String] = []
            var k = j
            for _ in 0..<macro.arity {
                Self.skipSpaces(chars, &k)
                if let (arg, after) = Self.group(chars, k) {
                    args.append(arg); k = after
                } else if k < chars.count {
                    args.append(String(chars[k])); k += 1
                }
            }
            var body = macro.body
            for (n, arg) in args.enumerated().reversed() {
                body = body.replacingOccurrences(of: "#\(n + 1)", with: arg)
            }
            // Keep a following letter from fusing with a control word at the end of the body.
            if k < chars.count, chars[k].isLetter, body.last?.isLetter == true { body += " " }
            out += body
            i = k
        }
        return out
    }

    private func rewriteCommand(_ s: String, _ command: String, to replacement: String) -> String {
        s.replacingOccurrences(of: command + "{", with: replacement + "{")
    }

    private static func matches(_ word: String, _ chars: [Character], _ i: Int) -> Bool {
        let w = Array(word)
        guard i + w.count <= chars.count, Array(chars[i..<(i + w.count)]) == w else { return false }
        let end = i + w.count
        return end == chars.count || !chars[end].isLetter || word.last == "*"
    }

    private static func skipSpaces(_ chars: [Character], _ i: inout Int) {
        while i < chars.count, chars[i].isWhitespace { i += 1 }
    }

    /// Reads a balanced `{…}` group starting at `i`, returning its contents and the index after it.
    private static func group(_ chars: [Character], _ start: Int) -> (String, Int)? {
        var i = start
        skipSpaces(chars, &i)
        guard i < chars.count, chars[i] == "{" else { return nil }
        var depth = 0
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if c == "{" { depth += 1; if depth > 1 { out.append(c) } }
            else if c == "}" { depth -= 1; if depth == 0 { return (out, i + 1) }; out.append(c) }
            else { out.append(c) }
            i += 1
        }
        return nil
    }

    private static func stripBackslash(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).hasPrefix("\\")
            ? String(s.trimmingCharacters(in: .whitespaces).dropFirst()) : s
    }
}
