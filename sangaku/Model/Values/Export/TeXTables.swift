import Foundation

/// What the TeX gate lets through. Every command here is set by pdfLaTeX with amsmath, amssymb, mathtools and
/// mathrsfs; a test compiles each one with the real TeX and with the hashtag kit's preamble.
nonisolated enum TeXTables {
    /// Commands allowed in mathematics: the renderer's own tables (tier 1 symbols, Greek, operator names and the
    /// commands whose arguments the validator counts), less colour, plus the common commands of tier 2.
    static let mathCommands: Set<String> = {
        var commands = Set(TypographicMath.symbols.keys).union(TypographicMath.greek.keys)
            .union(TypographicMath.operatorNames).union(TeXValidator.arity.keys)
        commands.subtract(["color", "textcolor", "lt", "gt"])
        return commands.union(extraMathCommands)
    }()

    private static let extraMathCommands: Set<String> = [
        // Large operators and limits
        "sum", "prod", "coprod", "int", "iint", "iiint", "oint", "bigcup", "bigcap", "bigoplus", "bigotimes",
        "bigodot", "biguplus", "bigsqcup", "bigvee", "bigwedge", "lim", "limsup", "liminf", "varprojlim",
        "varinjlim", "injlim", "projlim", "Pr", "limits", "nolimits",
        // Delimiters and sizes
        "left", "right", "middle", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr",
        "Biggl", "Biggr", "lbrace", "rbrace", "lbrack", "rbrack", "backslash", "uparrow", "downarrow", "updownarrow",
        "Uparrow", "Downarrow",
        // Spacing and dots
        "quad", "qquad", "thinspace", "medspace", "thickspace", "negthinspace", "vdots", "ddots", "dotsb", "dotsm",
        "dotsi", "dotso",
        // Congruences, negation, styles, classes
        "mod", "bmod", "pod", "not", "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "mathop",
        "mathbin", "mathrel", "mathord", "mathpunct", "mathopen", "mathclose", "mathnormal", "textnormal", "textsf",
        "texttt", "vphantom", "hphantom", "smash", "pmb", "overleftarrow", "overrightarrow", "hline",
        "begin", "end",
        // Further symbols
        "setminus", "smallsetminus", "dagger", "ddagger", "star", "bullet", "diamond", "wr", "amalg", "sqcup", "sqcap",
        "uplus", "odot", "ominus", "oslash", "bigcirc", "leftrightarrow", "longleftarrow", "longleftrightarrow",
        "Longrightarrow", "Longleftarrow", "Longleftrightarrow", "nearrow", "searrow", "rightleftharpoons",
        "triangle", "square", "blacksquare", "lozenge", "sharp", "flat", "natural", "hbar", "imath", "jmath", "wp",
        "Re", "Im", "complement", "mho", "beth", "gimel", "leqq", "geqq", "lesssim", "gtrsim", "prec", "succ",
        "preceq", "succeq", "asymp", "doteq", "sqsubseteq", "sqsupseteq", "subsetneqq", "supsetneqq", "ncong",
        "nleq", "ngeq", "nless", "ngtr", "nsim", "nparallel", "rtimes", "ltimes", "rhd", "unrhd", "trianglerighteq",
        "triangleright", "vartriangleleft", "vartriangleright", "therefore", "because", "emptyset", "varnothing",
    ]

    /// Commands whose braced argument is text, not mathematics.
    static let textArguments: Set<String> = ["text", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal", "mbox"]

    /// Environments allowed in mathematics; `\\` and `&` only inside them (or a `\substack` argument).
    static let environments: Set<String> = [
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "cases", "aligned",
        "gathered", "split", "array",
    ]

    /// Commands the app reads but LaTeX lacks, rewritten exactly.
    static let mathRewrites: [String: String] = ["lt": "<", "gt": ">"]

    /// Control symbols allowed in mathematics: spaces, braces and the escaped specials.
    static let mathSymbols: Set<Character> = [",", ";", ":", "!", " ", "{", "}", "|", "%", "$", "#", "&", "_"]

    /// Unicode in mathematics, with the TeX that sets it. The trailing space keeps a following letter apart.
    static let mathForms: [Character: String] = {
        var forms: [Character: String] = [:]
        // Prefer the shortest name, then the first in alphabetical order, so the table is the same on every run.
        for (name, entry) in TypographicMath.symbols.sorted(by: { ($0.key.count, $0.key) < ($1.key.count, $1.key) })
        where entry.0.count == 1 && !(entry.0.first?.isASCII ?? true) && !["lt", "gt"].contains(name) {
            if let glyph = entry.0.first, forms[glyph] == nil { forms[glyph] = "\\" + name + " " }
        }
        for (name, glyph) in TypographicMath.greek.sorted(by: { $0.key < $1.key }) {
            if let glyph = glyph.first, forms[glyph] == nil { forms[glyph] = "\\" + name + " " }
        }
        for (glyph, letter) in [("ℕ", "N"), ("ℤ", "Z"), ("ℚ", "Q"), ("ℝ", "R"), ("ℂ", "C")] {
            forms[Character(glyph)] = "\\mathbb{\(letter)}"
        }
        forms["−"] = "-"
        forms["∣"] = "\\mid "
        forms["′"] = "'"
        return forms
    }()

    static let superscripts: [Character: Character] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
        "⁺": "+", "⁻": "-", "ⁿ": "n",
    ]
    static let subscripts: [Character: Character] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9",
        "₊": "+", "₋": "-",
    ]

    /// Unicode in text that pdfLaTeX cannot set directly, with the TeX that sets it.
    static let textForms: [Character: String] = {
        var forms: [Character: String] = [:]
        for (glyph, form) in mathForms { forms[glyph] = "\\ensuremath{" + form.trimmingCharacters(in: .whitespaces) + "}" }
        for (glyph, digit) in superscripts { forms[glyph] = "\\textsuperscript{\(digit == "-" ? "\\ensuremath{-}" : String(digit))}" }
        for (glyph, digit) in subscripts { forms[glyph] = "\\textsubscript{\(digit == "-" ? "\\ensuremath{-}" : String(digit))}" }
        forms["−"] = "\\ensuremath{-}"
        forms["\u{00A0}"] = "~"
        forms["\u{2009}"] = "\\,"
        forms["\u{202F}"] = "\\,"
        // Set directly in T1: kept out of this table.
        for glyph in passedPunctuation { forms.removeValue(forKey: glyph) }
        return forms
    }()

    /// Punctuation and signs pdfLaTeX sets from UTF-8 input in T1, as typed.
    static let passedPunctuation: Set<Character> = [
        "–", "—", "‘", "’", "“", "”", "„", "…", "«", "»", "‹", "›", "§", "¶", "©", "®", "°", "·", "•", "†", "‡",
        "¡", "¿", "£",
    ]

    /// A letter pdfLaTeX sets from UTF-8 input in T1: Latin-1 and Latin Extended-A letters, × and ÷ aside.
    static func passesInText(_ character: Character) -> Bool {
        if passedPunctuation.contains(character) { return true }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0xC0...0xFF: return scalar.value != 0xD7 && scalar.value != 0xF7
        case 0x100...0x17F: return !excludedExtendedA.contains(scalar.value)
        default: return false
        }
    }

    /// Latin Extended-A letters pdfLaTeX's T1 setup cannot set (found by compiling each one).
    static let excludedExtendedA: Set<UInt32> = [0x126, 0x127, 0x138, 0x13F, 0x140, 0x149, 0x166, 0x167, 0x17F]

    /// Names a problem's macro may not take: what the document's structure, the gate's own output and the kit use.
    static let protectedMacroNames: Set<String> = [
        "begin", "end", "par", "relax", "section", "subsection", "subsubsection", "chapter", "paragraph", "part",
        "label", "ref", "eqref", "pageref", "cite", "nocite", "input", "include", "includeonly", "write", "openin",
        "openout", "read", "immediate", "special", "catcode", "def", "edef", "gdef", "xdef", "let", "csname",
        "endcsname", "expandafter", "noexpand", "usepackage", "RequirePackage", "documentclass", "newcommand",
        "renewcommand", "providecommand", "newenvironment", "renewenvironment", "item", "maketitle", "title",
        "author", "date", "document", "proof", "qed", "qedhere", "qedsymbol", "textbackslash", "textasciicircum",
        "textasciitilde", "textless", "textgreater", "textsuperscript", "textsubscript", "ensuremath",
        "textasciigrave", "url", "href", "hyperref", "htagsalt", "imported", "newitem", "newtheorem", "theoremstyle",
        "bibliography", "bibliographystyle", "bibitem", "appendix", "tableofcontents", "footnote", "marginpar",
        "text", "mathrm", "mathbb", "operatorname", "left", "right", "emph", "textit", "textbf", "textsc", "noindent",
        "newline", "linewidth", "textwidth", "tabular", "toprule", "midrule", "bottomrule", "multicolumn",
        "enumerate", "itemize", "description", "center", "thebibliography", "abstract", "status",
        "theorem", "lemma", "claim", "conjecture", "counterexample", "remark", "proposition", "corollary",
        "definition", "notation", "example", "warning", "question", "hypothesis", "heuristic", "experiment",
        "construction", "variant", "Large", "large", "small", "footnotesize", "bfseries", "itshape", "normalfont",
    ]

    static let protectedMacroPrefixes = ["end", "if", "htag", "htp", "sgk"]
}
