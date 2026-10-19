import AppKit
@preconcurrency import SwiftMath

/// Candidate: SwiftMath, optionally with a compatibility layer of exact equivalents only. Lossy stand-ins
/// (dropping an arrow's label, a brace, a box) are deliberately left out: they would render wrong math
/// that looks right.
final class SwiftMathEngine: MathEngine {
    let name: String
    let macros: MacroSet
    let fontSize: CGFloat
    let compat: Bool
    private var registeredOperators: Set<String> = []

    init(macros: MacroSet, fontSize: CGFloat = 16, compat: Bool) {
        self.macros = macros
        self.fontSize = fontSize
        self.compat = compat
        name = compat ? "SwiftMath + compatibility" : "SwiftMath"
        if compat { Self.registerSymbols() }
    }

    static func registerSymbols() {
        let symbols: [(String, MTMathAtomType, String)] = [
            ("nmid", .relation, "\u{2224}"), ("lvert", .open, "|"), ("rvert", .close, "|"),
            ("lVert", .open, "\u{2016}"), ("rVert", .close, "\u{2016}"), ("dots", .ordinary, "\u{2026}"),
            ("hookrightarrow", .relation, "\u{21AA}"), ("hookleftarrow", .relation, "\u{21A9}"),
            ("twoheadrightarrow", .relation, "\u{21A0}"), ("vdash", .relation, "\u{22A2}"),
            ("models", .relation, "\u{22A8}"), ("varnothing", .ordinary, "\u{2205}"),
            ("trianglelefteq", .relation, "\u{22B4}"), ("unlhd", .relation, "\u{22B4}"), ("lhd", .relation, "\u{22B2}"),
            ("geqslant", .relation, "\u{2A7E}"), ("leqslant", .relation, "\u{2A7D}"),
            ("nsubseteq", .relation, "\u{2288}"), ("subsetneq", .relation, "\u{228A}"), ("nequiv", .relation, "\u{2262}"),
            ("top", .ordinary, "\u{22A4}"), ("bot", .ordinary, "\u{22A5}"), ("lfloor", .open, "\u{230A}"),
            ("rfloor", .close, "\u{230B}"), ("lceil", .open, "\u{2308}"), ("rceil", .close, "\u{2309}"),
            ("coloneqq", .relation, "\u{2254}"), ("mapsfrom", .relation, "\u{21A4}"),
        ]
        // MTMathAtom's initializer is internal: copy an existing atom of the same type and swap its glyph.
        let templates: [MTMathAtomType: String] = [.relation: "equiv", .ordinary: "ldots", .open: "langle", .close: "rangle"]
        for (name, type, value) in symbols {
            guard let template = templates[type], let atom = MTMathAtomFactory.atom(forLatexSymbol: template)?.copy() else { continue }
            atom.nucleus = value
            MTMathAtomFactory.add(latexSymbol: name, value: atom)
        }
        for op in ["Hom", "Aut", "End", "im", "rank", "Gal", "Syl", "Spec", "colim", "Ext", "Tor", "id"] {
            MTMathAtomFactory.add(latexSymbol: "op" + op, value: MTMathAtomFactory.operatorWithName(op, limits: false))
        }
    }

    /// Exact rewrites only.
    func compatible(_ tex: String) -> String {
        var s = macros.expand(tex)
        // \operatorname{X} → a registered operator named X (operator spacing, upright).
        while let range = s.range(of: #"\\operatorname\*?\{([A-Za-z]+)\}"#, options: .regularExpression) {
            let match = String(s[range])
            let name = match.drop(while: { $0 != "{" }).dropFirst().dropLast()
            let key = "op" + name
            if !registeredOperators.contains(key) {
                MTMathAtomFactory.add(latexSymbol: key, value: MTMathAtomFactory.operatorWithName(String(name), limits: match.contains("*")))
                registeredOperators.insert(key)
            }
            s.replaceSubrange(range, with: "\\" + key + " ")
        }
        let rewrites: [(String, String)] = [
            (#"\\pmod\{([^{}]*)\}"#, #"\\;(\\mathrm{mod}\\;$1)"#),
            (#"\\bmod(?![A-Za-z])"#, #"\\;\\mathrm{mod}\\;"#),
            (#"\\tfrac(?![A-Za-z])"#, #"\\frac"#),
            (#"\\not\s*\\equiv"#, #"\\nequiv"#),
            (#"\\not\s*="#, #"\\neq"#),
            (#"\\begin\{gathered\}"#, #"\\begin{gather}"#),
            (#"\\end\{gathered\}"#, #"\\end{gather}"#),
        ]
        for (pattern, template) in rewrites {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }

    func layout(_ tex: String, display: Bool) -> Result<MathBox, EngineError> {
        let label = MTMathUILabel()
        label.labelMode = display ? .display : .text
        label.font = MTFontManager.manager.xitsFont(withSize: fontSize)
        label.latex = compat ? compatible(tex) : macros.expand(tex)
        if let error = label.error { return .failure(EngineError(message: error.localizedDescription)) }
        label.frame.size = label.fittingSize
        label.layout()
        guard let list = label.displayList else { return .failure(EngineError(message: "no display list")) }
        let ascent = list.ascent, descent = list.descent
        return .success(MathBox(width: list.width, ascent: ascent, descent: descent) { context in
            // SwiftMath draws y-up with the baseline at y = descent inside its own frame.
            context.saveGState()
            context.translateBy(x: 0, y: ascent + descent)
            context.scaleBy(x: 1, y: -1)
            list.draw(context)
            context.restoreGState()
        })
    }
}
