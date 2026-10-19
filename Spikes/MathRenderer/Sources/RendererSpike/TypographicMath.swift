import SwiftUI

/// Candidate: typographic inline math. A conservative LaTeX subset (letters, digits, common symbols,
/// Greek, \mathbb/\mathcal/\mathrm/\operatorname, simple sub- and superscripts, \pmod) is set as styled
/// text with TeX's inter-atom spacing. Anything else returns nil and goes to a typesetting engine.
enum TypographicMath {
    enum Atom { case ord, op, bin, rel, open, close, punct }

    struct Piece {
        var text: String
        var italic: Bool
        var atom: Atom
        var script: Int = 0 // 0 base, 1 superscript, -1 subscript
    }

    static let symbols: [String: (String, Atom)] = [
        "in": ("∈", .rel), "notin": ("∉", .rel), "ni": ("∋", .rel), "equiv": ("≡", .rel), "mid": ("∣", .rel),
        "nmid": ("∤", .rel), "le": ("≤", .rel), "leq": ("≤", .rel), "ge": ("≥", .rel), "geq": ("≥", .rel),
        "leqslant": ("⩽", .rel), "geqslant": ("⩾", .rel), "neq": ("≠", .rel), "ne": ("≠", .rel), "lt": ("<", .rel),
        "gt": (">", .rel), "subseteq": ("⊆", .rel), "subset": ("⊂", .rel), "supseteq": ("⊇", .rel), "supset": ("⊃", .rel),
        "subsetneq": ("⊊", .rel), "nsubseteq": ("⊈", .rel), "to": ("→", .rel), "mapsto": ("↦", .rel),
        "rightarrow": ("→", .rel), "leftarrow": ("←", .rel), "Rightarrow": ("⇒", .rel), "Leftarrow": ("⇐", .rel),
        "iff": ("⟺", .rel), "implies": ("⟹", .rel), "longrightarrow": ("⟶", .rel), "hookrightarrow": ("↪", .rel),
        "twoheadrightarrow": ("↠", .rel), "cong": ("≅", .rel), "simeq": ("≃", .rel), "sim": ("∼", .rel),
        "approx": ("≈", .rel), "trianglelefteq": ("⊴", .rel), "unlhd": ("⊴", .rel), "lhd": ("⊲", .rel),
        "perp": ("⊥", .rel), "vdash": ("⊢", .rel), "models": ("⊨", .rel), "coloneqq": ("≔", .rel),
        "cdot": ("⋅", .bin), "times": ("×", .bin), "pm": ("±", .bin), "mp": ("∓", .bin), "circ": ("∘", .bin),
        "cup": ("∪", .bin), "cap": ("∩", .bin), "setminus": ("∖", .bin), "oplus": ("⊕", .bin), "otimes": ("⊗", .bin),
        "wedge": ("∧", .bin), "vee": ("∨", .bin), "ast": ("∗", .bin),
        "infty": ("∞", .ord), "emptyset": ("∅", .ord), "varnothing": ("∅", .ord), "ell": ("ℓ", .ord),
        "partial": ("∂", .ord), "nabla": ("∇", .ord), "forall": ("∀", .ord), "exists": ("∃", .ord), "neg": ("¬", .ord),
        "prime": ("′", .ord), "aleph": ("ℵ", .ord), "top": ("⊤", .ord), "bot": ("⊥", .ord),
        "ldots": ("…", .ord), "dots": ("…", .ord), "cdots": ("⋯", .ord),
        "lvert": ("|", .open), "rvert": ("|", .close), "lVert": ("‖", .open), "rVert": ("‖", .close),
        "langle": ("⟨", .open), "rangle": ("⟩", .close), "lfloor": ("⌊", .open), "rfloor": ("⌋", .close),
        "lceil": ("⌈", .open), "rceil": ("⌉", .close), "{": ("{", .open), "}": ("}", .close), "|": ("‖", .ord),
    ]

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ",
        "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    static let operators: Set<String> = ["ker", "deg", "dim", "det", "gcd", "lcm", "log", "ln", "exp", "sin", "cos",
                                          "tan", "max", "min", "sup", "inf", "hom", "Hom", "Aut", "End", "im", "rank", "Gal"]

    static func alphabet(_ font: String, _ c: Character) -> String? {
        let special: [String: [Character: String]] = [
            "mathbb": ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"],
            "mathcal": ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ"],
            "mathfrak": ["C": "ℭ", "H": "ℌ", "I": "ℑ", "R": "ℜ", "Z": "ℨ"],
        ]
        if let s = special[font]?[c] { return s }
        guard let v = c.asciiValue else { return nil }
        let base: UInt32
        switch (font, c.isUppercase) {
        case ("mathbb", true): base = 0x1D538 - 65
        case ("mathcal", true): base = 0x1D49C - 65
        case ("mathfrak", true): base = 0x1D504 - 65
        case ("mathfrak", false): base = 0x1D51E - 97
        default: return nil
        }
        return UnicodeScalar(base + UInt32(v)).map { String(Character($0)) }
    }

    /// Parses `tex` into pieces, or nil if it leaves the supported subset.
    static func pieces(_ tex: String) -> [Piece]? {
        var chars = Array(tex)[...]
        var out: [Piece] = []
        func skipSpaces() { while chars.first?.isWhitespace == true { chars.removeFirst() } }
        func command() -> String {
            chars.removeFirst() // backslash
            guard let first = chars.first else { return "" }
            if !first.isLetter { chars.removeFirst(); return String(first) }
            var name = ""
            while let c = chars.first, c.isLetter { name.append(c); chars.removeFirst() }
            return name
        }
        func group() -> String? {
            skipSpaces()
            guard chars.first == "{" else {
                guard let c = chars.first else { return nil }
                chars.removeFirst(); return String(c)
            }
            chars.removeFirst()
            var depth = 1, s = ""
            while let c = chars.first {
                chars.removeFirst()
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { return s } }
                s.append(c)
            }
            return nil
        }
        while true {
            skipSpaces()
            guard let c = chars.first else { break }
            if c == "^" || c == "_" {
                chars.removeFirst()
                guard let inner = group(), let sub = pieces(inner), !sub.contains(where: { $0.script != 0 }),
                      let last = out.last, last.script == 0 else { return nil }
                // A base carrying both scripts stacks them in TeX; text cannot, so leave it to the engine.
                if let next = chars.drop(while: { $0.isWhitespace }).first, next == "^" || next == "_" { return nil }
                out += sub.map { var p = $0; p.script = c == "^" ? 1 : -1; return p }
            } else if c == "\\" {
                let name = command()
                if let (s, atom) = symbols[name] { out.append(Piece(text: s, italic: false, atom: atom)) }
                else if let g = greek[name] { out.append(Piece(text: g, italic: name.first!.isLowercase, atom: .ord)) }
                else if operators.contains(name) { out.append(Piece(text: name, italic: false, atom: .op)) }
                else if name == "," || name == ";" || name == "quad" || name == " " || name == ":" || name == "!" {
                    let space = ["," : "\u{2006}", ";" : "\u{2005}", ":" : "\u{205F}", " ": " ", "quad": "\u{2003}", "!": ""][name]!
                    out.append(Piece(text: space, italic: false, atom: .punct))
                } else if ["mathbb", "mathcal", "mathfrak"].contains(name) {
                    guard let arg = group() else { return nil }
                    for ch in arg where !ch.isWhitespace {
                        guard let mapped = alphabet(name, ch) else { return nil }
                        out.append(Piece(text: mapped, italic: false, atom: .ord))
                    }
                } else if name == "mathrm" || name == "text" || name == "operatorname" {
                    guard let arg = group(), !arg.contains("\\"), !arg.contains("$") else { return nil }
                    out.append(Piece(text: arg, italic: false, atom: name == "operatorname" ? .op : .ord))
                } else if name == "pmod" {
                    guard let arg = group(), let inner = pieces(arg) else { return nil }
                    out.append(Piece(text: "\u{2004}(", italic: false, atom: .open))
                    out.append(Piece(text: "mod\u{2006}", italic: false, atom: .ord))
                    out += inner
                    out.append(Piece(text: ")", italic: false, atom: .close))
                } else {
                    return nil
                }
            } else if c == "{" {
                guard let inner = group(), let sub = pieces(inner) else { return nil }
                out += sub
            } else {
                chars.removeFirst()
                if c.isLetter && c.isASCII { out.append(Piece(text: String(c), italic: true, atom: .ord)) }
                else if c.isNumber || c == "." && out.last?.text.last?.isNumber == true { out.append(Piece(text: String(c), italic: false, atom: .ord)) }
                else if "=<>".contains(c) { out.append(Piece(text: String(c), italic: false, atom: .rel)) }
                else if c == "+" { out.append(Piece(text: "+", italic: false, atom: .bin)) }
                else if c == "-" { out.append(Piece(text: "\u{2212}", italic: false, atom: .bin)) }
                else if "([".contains(c) { out.append(Piece(text: String(c), italic: false, atom: .open)) }
                else if ")]".contains(c) { out.append(Piece(text: String(c), italic: false, atom: .close)) }
                else if ",;".contains(c) { out.append(Piece(text: String(c), italic: false, atom: .punct)) }
                else if c == "|" { out.append(Piece(text: "|", italic: false, atom: .ord)) }
                else if c == "/" || c == "'" || c == "!" { out.append(Piece(text: c == "'" ? "′" : String(c), italic: false, atom: .ord)) }
                else { return nil }
            }
        }
        return out
    }

    /// TeX's spacing between adjacent atoms in text style (TeXbook, chapter 18), in Unicode spaces:
    /// thin 3mu ≈ U+2006, medium 4mu ≈ U+205F, thick 5mu ≈ U+2005.
    static func space(_ a: Atom, _ b: Atom) -> String {
        switch (a, b) {
        case (.ord, .op), (.op, .ord), (.op, .op), (.close, .op), (.punct, _): return "\u{2006}"
        case (.ord, .bin), (.bin, .ord), (.bin, .op), (.bin, .open), (.close, .bin): return "\u{205F}"
        case (.ord, .rel), (.rel, .ord), (.rel, .op), (.rel, .open), (.close, .rel), (.op, .rel): return "\u{2005}"
        default: return ""
        }
    }

    /// Builds the styled text, or nil if `tex` needs a real typesetter.
    static func text(_ tex: String, size: CGFloat = 16) -> Text? {
        guard var ps = pieces(tex), !ps.isEmpty else { return nil }
        // TeX rule: a binary operator with no left operand (or before a relation, closer or punctuation) is ordinary.
        for i in ps.indices where ps[i].atom == .bin {
            let prev = i > 0 ? ps[i - 1].atom : nil
            let next = i + 1 < ps.count ? ps[i + 1].atom : nil
            if prev == nil || [.bin, .op, .rel, .open, .punct].contains(prev!) || [.rel, .close, .punct].contains(next ?? .ord) {
                ps[i].atom = .ord
            }
        }
        var result = Text("")
        let joiner = "\u{2060}"
        // A scripted atom keeps its nucleus's class, so spacing is decided between base-level atoms.
        var previousBase: Atom?
        for (i, p) in ps.enumerated() {
            if p.script == 0, let prev = previousBase {
                let gap = space(prev, p.atom)
                // Allow a line break only after relations and binary operators, as TeX does.
                let breakable = prev == .rel || prev == .bin
                result = result + Text(breakable ? gap : joiner + gap + joiner)
            } else if i > 0 {
                result = result + Text(joiner)
            }
            if p.script == 0 { previousBase = p.atom }
            // Symbols come from STIX Two Math; STIX Two Text lacks many (∣, ≅, ⊴…) and the fallback font differs.
            let isSymbol = !(p.text.first?.isLetter ?? false) && !(p.text.first?.isNumber ?? false)
                && !"()[]{},;.|/′".contains(p.text) && !p.text.hasPrefix("\u{2004}")
            let pieceSize = p.script == 0 ? size : size * 0.7
            var piece = Text(p.text)
            if isSymbol { piece = piece.font(.custom("STIX Two Math", size: pieceSize)) }
            else if p.script != 0 { piece = piece.font(.custom("STIX Two Text", size: pieceSize)) }
            if p.italic { piece = piece.italic() }
            if p.script != 0 { piece = piece.baselineOffset(p.script > 0 ? size * 0.36 : -size * 0.18) }
            result = result + piece
        }
        return result
    }
}

/// Fast path first, engine for the rest.
final class HybridMath {
    let math: InlineMath
    let macros: MacroSet
    private(set) var fastCount = 0
    private(set) var engineCount = 0

    init(engine: MathEngine, macros: MacroSet) {
        math = InlineMath(engine: engine)
        self.macros = macros
    }

    func paragraph(_ prose: String, salt: Int = 0) -> Text {
        var text = Text("")
        let joiner = "\u{2060}"
        for segment in Corpus.segments(prose) {
            switch segment {
            case .text(var s):
                if let first = s.first, !first.isWhitespace { s = joiner + s }
                if let last = s.last, !last.isWhitespace { s += joiner }
                text = text + Text(s)
            case .math(let tex):
                if let fast = TypographicMath.text(macros.expand(tex)) {
                    fastCount += 1
                    text = text + fast
                } else if let r = math.rendered(tex, salt: salt) {
                    engineCount += 1
                    text = text + Text(Image(nsImage: r.image).renderingMode(.template)).baselineOffset(-r.descent)
                } else {
                    text = text + Text(tex).foregroundStyle(.red)
                }
            }
        }
        return text
    }
}

struct HybridRow: View {
    let math: HybridMath
    let prose: String
    var salt = 0

    var body: some View {
        math.paragraph(prose, salt: salt)
            .font(.custom("STIX Two Text", size: 16))
            .foregroundStyle(Color(red: 0x16 / 255, green: 0x18 / 255, blue: 0x1D / 255))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.92)).frame(height: 1) }
    }
}
