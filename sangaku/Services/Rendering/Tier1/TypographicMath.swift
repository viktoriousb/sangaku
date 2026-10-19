import Foundation

/// One styled run of tier-1 math. A formula is an array of runs that `MathTextComposer` turns into `Text`.
nonisolated struct MathRun: Hashable, Sendable {
    nonisolated enum Face: Hashable, Sendable {
        /// STIX Two Text: letters, digits, words.
        case text
        /// STIX Two Math: symbols, which STIX Two Text lacks or draws differently.
        case math
    }

    nonisolated enum Script: Hashable, Sendable {
        case base, superscript, `subscript`
    }

    var text: String
    var face: Face
    var italic: Bool
    var script: Script
}

/// Tier 1: sets a conservative subset of LaTeX as styled text with TeX's spacing between atoms.
///
/// The subset is letters, digits, Greek, the common relations, operators and delimiters, `\mathbb`,
/// `\mathcal`, `\mathfrak`, `\mathrm`, `\text`, `\operatorname`, `\pmod`, `\bmod`, exact `\not` negations, explicit
/// spaces, and at most one sub- or superscript per atom. Anything else returns nil, and the formula goes to
/// tier 2. Tier 1 never approximates: it either sets the formula exactly or declines.
nonisolated enum TypographicMath {
    enum AtomClass: Hashable {
        case ord, op, bin, rel, open, close, punct
    }

    struct Atom: Hashable {
        var atomClass: AtomClass
        var nucleus: [MathRun]
        var superscript: [MathRun]?
        var subscriptRuns: [MathRun]?
        /// Explicit spacing (`\,`, `\quad`): glue, not an atom, so it takes no automatic spacing and no scripts.
        var isSpace = false
    }

    static let symbols: [String: (String, AtomClass)] = [
        // Relations
        "in": ("∈", .rel), "notin": ("∉", .rel), "ni": ("∋", .rel), "equiv": ("≡", .rel), "mid": ("∣", .rel),
        "nmid": ("∤", .rel), "le": ("≤", .rel), "leq": ("≤", .rel), "ge": ("≥", .rel), "geq": ("≥", .rel),
        "leqslant": ("⩽", .rel), "geqslant": ("⩾", .rel), "neq": ("≠", .rel), "ne": ("≠", .rel),
        "lt": ("<", .rel), "gt": (">", .rel), "ll": ("≪", .rel), "gg": ("≫", .rel),
        "subseteq": ("⊆", .rel), "subset": ("⊂", .rel), "supseteq": ("⊇", .rel), "supset": ("⊃", .rel),
        "subsetneq": ("⊊", .rel), "supsetneq": ("⊋", .rel), "nsubseteq": ("⊈", .rel),
        "to": ("→", .rel), "mapsto": ("↦", .rel), "rightarrow": ("→", .rel), "leftarrow": ("←", .rel),
        "Rightarrow": ("⇒", .rel), "Leftarrow": ("⇐", .rel), "Leftrightarrow": ("⇔", .rel),
        "iff": ("⟺", .rel), "implies": ("⟹", .rel), "impliedby": ("⟸", .rel),
        "longrightarrow": ("⟶", .rel), "longmapsto": ("⟼", .rel),
        "hookrightarrow": ("↪", .rel), "twoheadrightarrow": ("↠", .rel),
        "cong": ("≅", .rel), "simeq": ("≃", .rel), "sim": ("∼", .rel), "approx": ("≈", .rel),
        "propto": ("∝", .rel), "perp": ("⊥", .rel), "parallel": ("∥", .rel),
        "trianglelefteq": ("⊴", .rel), "unlhd": ("⊴", .rel), "lhd": ("⊲", .rel), "triangleleft": ("◁", .bin),
        "vdash": ("⊢", .rel), "models": ("⊨", .rel), "coloneqq": ("≔", .rel),
        // Binary operators
        "cdot": ("⋅", .bin), "times": ("×", .bin), "pm": ("±", .bin), "mp": ("∓", .bin), "circ": ("∘", .bin),
        "cup": ("∪", .bin), "cap": ("∩", .bin), "setminus": ("∖", .bin), "oplus": ("⊕", .bin),
        "otimes": ("⊗", .bin), "wedge": ("∧", .bin), "land": ("∧", .bin), "vee": ("∨", .bin), "lor": ("∨", .bin),
        "ast": ("∗", .bin), "div": ("÷", .bin),
        // Ordinary symbols
        "infty": ("∞", .ord), "emptyset": ("∅", .ord), "varnothing": ("∅", .ord), "ell": ("ℓ", .ord),
        "partial": ("∂", .ord), "nabla": ("∇", .ord), "forall": ("∀", .ord), "exists": ("∃", .ord),
        "nexists": ("∄", .ord), "neg": ("¬", .ord), "lnot": ("¬", .ord), "prime": ("′", .ord),
        "aleph": ("ℵ", .ord), "top": ("⊤", .ord), "bot": ("⊥", .ord), "angle": ("∠", .ord),
        "ldots": ("…", .ord), "dots": ("…", .ord), "dotsc": ("…", .ord), "cdots": ("⋯", .ord),
        "colon": (":", .punct),
        // Delimiters
        "lvert": ("|", .open), "rvert": ("|", .close), "lVert": ("‖", .open), "rVert": ("‖", .close),
        "langle": ("⟨", .open), "rangle": ("⟩", .close), "lfloor": ("⌊", .open), "rfloor": ("⌋", .close),
        "lceil": ("⌈", .open), "rceil": ("⌉", .close), "vert": ("|", .ord), "Vert": ("‖", .ord),
    ]

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ",
        "nu": "ν", "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς",
        "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    static let operatorNames: Set<String> = [
        "ker", "deg", "dim", "det", "gcd", "log", "ln", "lg", "exp", "sin", "cos", "tan", "cot", "sec", "csc",
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "arg", "hom", "max", "min", "sup", "inf",
    ]

    /// Unicode that models often write directly in math.
    static let unicodeSymbols: [Character: AtomClass] = [
        "≠": .rel, "≤": .rel, "≥": .rel, "∈": .rel, "∉": .rel, "≡": .rel, "∣": .rel, "∤": .rel, "⊆": .rel,
        "⊂": .rel, "⊇": .rel, "⊃": .rel, "→": .rel, "↦": .rel, "≅": .rel, "≃": .rel, "∼": .rel, "≈": .rel,
        "⇒": .rel, "⇔": .rel, "⊴": .rel, "×": .bin, "⋅": .bin, "±": .bin, "∘": .bin, "∪": .bin, "∩": .bin,
        "⊕": .bin, "⊗": .bin, "−": .bin, "∞": .ord, "∅": .ord, "ℓ": .ord, "∂": .ord, "∇": .ord, "∀": .ord,
        "∃": .ord, "¬": .ord, "ℤ": .ord, "ℚ": .ord, "ℝ": .ord, "ℂ": .ord, "ℕ": .ord,
    ]

    private static let negations: [TeXToken: String] = [
        .char("="): "≠", .command("in"): "∉", .command("equiv"): "≢", .command("subset"): "⊄",
        .command("subseteq"): "⊈", .command("mid"): "∤", .char("<"): "≮", .char(">"): "≯",
    ]

    // MARK: Entry point

    /// The formula as runs, or nil if it leaves the subset.
    static func runs(for tex: String) -> [MathRun]? {
        guard var atoms = parse(TeXLexer.tokens(tex)), !atoms.isEmpty else { return nil }
        reclassifyBinaryOperators(&atoms)
        return layout(atoms)
    }

    // MARK: Parsing

    static func parse(_ tokens: [TeXToken]) -> [Atom]? {
        var atoms: [Atom] = []
        var i = 0
        func symbolAtom(_ text: String, _ atomClass: AtomClass, face: MathRun.Face = .math, italic: Bool = false) -> Atom {
            Atom(atomClass: atomClass, nucleus: [MathRun(text: text, face: face, italic: italic, script: .base)])
        }
        func space(_ text: String) -> Atom {
            Atom(atomClass: .ord, nucleus: [MathRun(text: text, face: .text, italic: false, script: .base)], isSpace: true)
        }
        while i < tokens.count {
            let token = tokens[i]
            switch token {
            case .space:
                i += 1

            case .char("^"), .char("_"):
                guard let argument = tokens.argument(at: i + 1), let scriptAtoms = parse(argument.contents),
                      !scriptAtoms.contains(where: { $0.superscript != nil || $0.subscriptRuns != nil }),
                      scriptAtoms.allSatisfy({ $0.nucleus.allSatisfy { $0.script == .base } }),
                      let last = atoms.indices.last, !atoms[last].isSpace,
                      atoms[last].superscript == nil, atoms[last].subscriptRuns == nil,
                      atoms[last].nucleus.allSatisfy({ $0.script == .base })
                else { return nil } // nested, doubled or stacked scripts (`{p^2}^3`) are tier 2's job
                let isSuper = token == .char("^")
                let runs = scriptAtoms.flatMap(\.nucleus).map {
                    MathRun(text: $0.text, face: $0.face, italic: $0.italic, script: isSuper ? .superscript : .subscript)
                }
                if isSuper { atoms[last].superscript = runs } else { atoms[last].subscriptRuns = runs }
                i = argument.end

            case .char(let c):
                i += 1
                if c.isASCII && c.isLetter { atoms.append(symbolAtom(String(c), .ord, face: .text, italic: true)) }
                else if c.isASCII && c.isNumber || c == "." { atoms.append(symbolAtom(String(c), .ord, face: .text)) }
                else if "=<>:".contains(c) { atoms.append(symbolAtom(String(c), .rel)) }
                else if c == "+" { atoms.append(symbolAtom("+", .bin)) }
                else if c == "-" { atoms.append(symbolAtom("−", .bin)) }
                else if c == "*" { atoms.append(symbolAtom("∗", .bin)) }
                else if "([".contains(c) { atoms.append(symbolAtom(String(c), .open, face: .text)) }
                else if ")]".contains(c) { atoms.append(symbolAtom(String(c), .close, face: .text)) }
                else if "!?".contains(c) { atoms.append(symbolAtom(String(c), .close, face: .text)) }
                else if ",;".contains(c) { atoms.append(symbolAtom(String(c), .punct, face: .text)) }
                else if c == "|" { atoms.append(symbolAtom("|", .ord)) }
                else if c == "/" { atoms.append(symbolAtom("/", .ord, face: .text)) }
                else if c == "'" { atoms.append(symbolAtom("′", .ord)) }
                else if c == "~" { atoms.append(space("\u{00A0}")) }
                else if let greekClass = greekLetterClass(c) { atoms.append(symbolAtom(String(c), greekClass, face: .text, italic: c.isLowercase)) }
                else if let symbolClass = unicodeSymbols[c] { atoms.append(symbolAtom(String(c), symbolClass)) }
                else { return nil }

            case .open:
                guard let group = tokens.group(at: i), var inner = parse(group.contents) else { return nil }
                reclassifyBinaryOperators(&inner)
                // A group is a single ordinary atom (TeX), so `{/}` or `{=}` takes no operator spacing.
                atoms.append(Atom(atomClass: .ord, nucleus: inner.isEmpty ? [] : layout(inner)))
                i = group.end

            case .close:
                return nil

            case .symbol(let c):
                i += 1
                switch c {
                case ",": atoms.append(space("\u{2006}"))        // thin, 3mu
                case ":", ">": atoms.append(space("\u{205F}"))   // medium, 4mu
                case ";": atoms.append(space("\u{2005}"))        // thick, 5mu
                case " ": atoms.append(space(" "))
                case "{": atoms.append(symbolAtom("{", .open, face: .text))
                case "}": atoms.append(symbolAtom("}", .close, face: .text))
                case "|": atoms.append(symbolAtom("‖", .ord))
                case "#", "$", "%", "&", "_": atoms.append(symbolAtom(String(c), .ord, face: .text))
                default: return nil // includes \! (negative space) and \\ (line break)
                }

            case .command(let name):
                if let (text, atomClass) = symbols[name] {
                    atoms.append(symbolAtom(text, atomClass))
                    i += 1
                } else if let letter = greek[name] {
                    atoms.append(symbolAtom(letter, .ord, face: .text, italic: name.first!.isLowercase))
                    i += 1
                } else if operatorNames.contains(name) {
                    atoms.append(symbolAtom(name, .op, face: .text))
                    i += 1
                } else if name == "quad" {
                    atoms.append(space("\u{2003}")); i += 1
                } else if name == "qquad" {
                    atoms.append(space("\u{2003}\u{2003}")); i += 1
                } else if ["mathbb", "mathcal", "mathfrak"].contains(name) {
                    guard let argument = tokens.argument(at: i + 1) else { return nil }
                    for t in argument.contents {
                        if case .space = t { continue }
                        guard case .char(let c) = t, let mapped = alphabet(name, c) else { return nil }
                        atoms.append(symbolAtom(mapped, .ord, face: .math))
                    }
                    i = argument.end
                } else if ["mathrm", "text", "textrm", "operatorname"].contains(name) {
                    // `\operatorname*` (limits) is tier 2's job; reading "*" as the argument would print it.
                    let next = tokens.skippingSpaces(from: i + 1)
                    if next < tokens.count, tokens[next] == .char("*") { return nil }
                    let isText = name == "text" || name == "textrm"
                    guard let argument = tokens.argument(at: i + 1),
                          let words = plainText(argument.contents, allowing: isText ? textCharacters : uprightMathCharacters)
                    else { return nil }
                    let shown = isText ? words : words.filter { !$0.isWhitespace }
                    guard !shown.isEmpty else { return nil }
                    atoms.append(symbolAtom(shown, name == "operatorname" ? .op : .ord, face: .text))
                    i = argument.end
                } else if name == "pmod" {
                    guard let argument = tokens.argument(at: i + 1), var inner = parse(argument.contents),
                          !inner.isEmpty else { return nil }
                    reclassifyBinaryOperators(&inner)
                    // amsmath, inline: \mkern8mu(\operator@font mod\mkern6mu #1)
                    atoms.append(space("\u{2005}\u{2006}"))
                    atoms.append(symbolAtom("(", .open, face: .text))
                    atoms.append(symbolAtom("mod", .ord, face: .text))
                    atoms.append(space("\u{2004}"))
                    atoms.append(Atom(atomClass: .ord, nucleus: layout(inner)))
                    atoms.append(symbolAtom(")", .close, face: .text))
                    i = argument.end
                } else if name == "bmod" {
                    atoms.append(symbolAtom("mod", .bin, face: .text))
                    i += 1
                } else if name == "not" {
                    let next = tokens.skippingSpaces(from: i + 1)
                    guard next < tokens.count, let negated = negations[tokens[next]] else { return nil }
                    atoms.append(symbolAtom(negated, .rel))
                    i = next + 1
                } else {
                    return nil
                }
            }
        }
        return atoms
    }

    private static func greekLetterClass(_ c: Character) -> AtomClass? {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return nil }
        return (0x03B1...0x03C9).contains(scalar.value) || (0x0393...0x03A9).contains(scalar.value) ? .ord : nil
    }

    /// Inside `\mathrm` and `\operatorname` only letters and digits are plain: `_`, `^` and the rest keep their
    /// math meaning there (`\mathrm{GL_n}` has a subscript), which text cannot show.
    private static func uprightMathCharacters(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// Inside `\text` also ordinary punctuation; not the characters TeX treats specially in text (`$`, `^`, `_`,
    /// `~`, `&`, `#`, `%`, quotes and dashes that form ligatures).
    private static func textCharacters(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber { return true }
        return ",.;:!?()[]/+=<>*@".contains(c)
    }

    /// The text of a group made only of allowed characters and spaces, or nil.
    private static func plainText(_ tokens: [TeXToken], allowing allowed: (Character) -> Bool) -> String? {
        var out = ""
        for t in tokens {
            switch t {
            case .char(let c) where allowed(c): out.append(c)
            case .space: out.append(" ")
            default: return nil
            }
        }
        return out
    }

    static func alphabet(_ font: String, _ c: Character) -> String? {
        let letterlike: [String: [Character: String]] = [
            "mathbb": ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"],
            "mathcal": ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ"],
            "mathfrak": ["C": "ℭ", "H": "ℌ", "I": "ℑ", "R": "ℜ", "Z": "ℨ"],
        ]
        if let s = letterlike[font]?[c] { return s }
        guard let v = c.asciiValue, c.isLetter else { return nil }
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

    // MARK: Spacing

    /// TeXbook rule: a binary operator with no left operand, or before a relation, closer or punctuation,
    /// is ordinary.
    static func reclassifyBinaryOperators(_ atoms: inout [Atom]) {
        let real = atoms.indices.filter { !atoms[$0].isSpace }
        for (k, i) in real.enumerated() where atoms[i].atomClass == .bin {
            let previous = k > 0 ? atoms[real[k - 1]].atomClass : nil
            let next = k + 1 < real.count ? atoms[real[k + 1]].atomClass : nil
            if previous == nil || [.bin, .op, .rel, .open, .punct].contains(previous!)
                || next == nil || [.rel, .close, .punct].contains(next!) {
                atoms[i].atomClass = .ord
            }
        }
    }

    /// TeX's spacing between atoms in text style (TeXbook, chapter 18) as Unicode spaces:
    /// thin 3mu ≈ U+2006 (1/6 em), medium 4mu ≈ U+205F (4/18 em), thick 5mu ≈ U+2005 (1/4 em).
    static func space(between a: AtomClass, and b: AtomClass) -> String {
        switch (a, b) {
        case (.ord, .op), (.op, .ord), (.op, .op), (.close, .op), (.punct, _): "\u{2006}"
        case (.ord, .bin), (.bin, .ord), (.bin, .op), (.bin, .open), (.close, .bin): "\u{205F}"
        case (.ord, .rel), (.rel, .ord), (.rel, .op), (.rel, .open), (.close, .rel), (.op, .rel): "\u{2005}"
        default: ""
        }
    }

    static let wordJoiner = "\u{2060}"

    /// Flattens atoms into runs with spacing. Line breaks are allowed only after relations and binary
    /// operators; everywhere else a word joiner holds the formula together.
    static func layout(_ atoms: [Atom]) -> [MathRun] {
        var runs: [MathRun] = []
        var previous: AtomClass?
        for atom in atoms {
            if atom.isSpace {
                runs.append(contentsOf: atom.nucleus)
                continue
            }
            if let prev = previous {
                let gap = space(between: prev, and: atom.atomClass)
                let breakable = prev == .rel || prev == .bin
                let glue = breakable ? gap : wordJoiner + gap + wordJoiner
                if !glue.isEmpty { runs.append(MathRun(text: glue, face: .text, italic: false, script: .base)) }
            } else if !runs.isEmpty {
                runs.append(MathRun(text: wordJoiner, face: .text, italic: false, script: .base))
            }
            runs.append(contentsOf: atom.nucleus)
            if let sub = atom.subscriptRuns { runs.append(contentsOf: sub) }
            if let sup = atom.superscript { runs.append(contentsOf: sup) }
            previous = atom.atomClass
        }
        return runs
    }
}
