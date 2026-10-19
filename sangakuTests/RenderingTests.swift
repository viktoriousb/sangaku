import AppKit
import Foundation
import Testing
@testable import sangaku

private func plain(_ runs: [MathRun]?) -> String? {
    runs?.map(\.text).joined().replacing(TypographicMath.wordJoiner, with: "")
}

@Suite("Tier 1: typographic math")
struct TypographicMathTests {
    @Test func setsSimpleFormulasWithTeXSpacing() {
        // thick space around relations (U+2005), medium around binary operators (U+205F)
        #expect(plain(TypographicMath.runs(for: "q > p")) == "q\u{2005}>\u{2005}p")
        #expect(plain(TypographicMath.runs(for: "p + 1")) == "p\u{205F}+\u{205F}1")
        #expect(plain(TypographicMath.runs(for: "-1")) == "−1") // unary minus is ordinary: no space
        #expect(plain(TypographicMath.runs(for: #"q \mid p+1"#)) == "q\u{2005}∣\u{2005}p\u{205F}+\u{205F}1")
    }

    @Test func lettersAreItalicAndSymbolsUseTheMathFont() throws {
        let runs = try #require(TypographicMath.runs(for: #"n \in G"#))
        let n = try #require(runs.first { $0.text == "n" })
        let element = try #require(runs.first { $0.text == "∈" })
        #expect(n.italic && n.face == .text)
        #expect(!element.italic && element.face == .math)
    }

    @Test func scriptsAndAlphabets() throws {
        let runs = try #require(TypographicMath.runs(for: #"n_p \equiv 1 \pmod{p}"#))
        #expect(runs.contains { $0.text == "p" && $0.script == .subscript })
        #expect(plain(runs)?.contains("(mod\u{2004}p)") == true)
        #expect(plain(TypographicMath.runs(for: #"\mathbb{Z}/n\mathbb{Z}"#)) == "ℤ/nℤ")
        #expect(plain(TypographicMath.runs(for: #"\operatorname{Syl}_r(G)"#))?.hasPrefix("Syl") == true)
    }

    @Test func breaksAreAllowedOnlyAfterRelationsAndBinaryOperators() throws {
        let runs = try #require(TypographicMath.runs(for: "a = b"))
        let glue = runs.filter { $0.text.contains("\u{2005}") }
        #expect(glue.count == 2)
        #expect(glue[0].text.hasPrefix(TypographicMath.wordJoiner))      // before "=": held
        #expect(!glue[1].text.hasPrefix(TypographicMath.wordJoiner))     // after "=": may break
    }

    @Test func pmodArgumentsUseTeXSpacing() {
        // A leading minus inside \pmod is unary: no space between it and the 1.
        #expect(plain(TypographicMath.runs(for: #"a \equiv b \pmod{-1}"#))?.contains("(mod\u{2004}−1)") == true)
    }

    @Test func exactNegationsOnly() {
        #expect(plain(TypographicMath.runs(for: #"a \not\equiv b"#))?.contains("≢") == true)
        #expect(TypographicMath.runs(for: #"a \not\approx b"#) == nil)
    }

    @Test("Anything outside the subset is declined, never approximated",
          arguments: [#"\frac{a}{b}"#, #"\sum_{k=0}^n k"#, #"x_i^2"#, #"{p^2}^3"#, #"x^{a^b}"#, #"\sqrt{2}"#,
                      #"\left( x \right)"#, #"\overline{x}"#, #"\hat{x}"#, #"\begin{cases}a\end{cases}"#,
                      #"\mathbf{v}"#, #"\unknowncommand"#, #"a \\ b"#, #"x\!y"#, "a & b", #"\xrightarrow{f}"#,
                      #"\operatorname*{colim}_i F(i)"#, #"\operatorname *{colim}"#, #"\mathrm{GL_n}"#, #"\mathrm{x^2}"#,
                      #"\operatorname{Hom_R}(M,N)"#, #"\text{ for $x>0$ }"#, #"\text{a~b}"#, #"\text{non--trivial}"#])
    func declines(_ tex: String) {
        #expect(TypographicMath.runs(for: tex) == nil)
    }
}

@Suite("Tier 2: MicroTeX", .serialized)
struct MicroTeXTests {
    private let typesetter = MicroTeXTypesetter.shared

    @Test func loadsItsFont() {
        guard case .ready(let name) = typesetter.state else {
            Issue.record("MicroTeX unavailable: \(typesetter.state)")
            return
        }
        #expect(!name.isEmpty)
    }

    @Test func typesetsWithPositiveMetrics() throws {
        let formula = try typesetter.typeset(#"\frac{a}{b}"#, fontSize: 16, display: false).get()
        #expect(formula.width > 0 && formula.ascent > 0 && formula.descent > 0)
        #expect(!formula.ops.isEmpty)
    }

    @Test("Patch 1: unknown commands and environments are errors, never raw source",
          arguments: [#"\undefinedcommand x"#, #"\begin{CD} A @>f>> B \end{CD}"#, #"\begin{nosuchenv}x\end{nosuchenv}"#])
    func strictParsing(_ tex: String) {
        guard case .failure(let diagnostic) = typesetter.typeset(tex, fontSize: 16, display: true) else {
            Issue.record("\(tex) was typeset")
            return
        }
        #expect(!diagnostic.message.isEmpty)
    }

    @Test("Patch 3: a parse error comes back as an error string, not a crash")
    func shimReturnsErrors() {
        guard case .failure(let diagnostic) = typesetter.typeset(#"a^^b \right)"#, fontSize: 16, display: false) else {
            Issue.record("invalid input was typeset")
            return
        }
        #expect(!diagnostic.message.isEmpty)
    }

    @Test("MicroTeX quietly repairs some broken input, which is why the renderer validates first")
    func microTeXRepairsBrokenInput() {
        // If this starts failing, MicroTeX became stricter; the validator stays as defence in depth.
        #expect((try? typesetter.typeset(#"\frac{a"#, fontSize: 16, display: false).get()) != nil)
    }

    @Test("Text typesets, and no text layouts are left behind after a formula")
    func textLayouts() throws {
        let formula = try typesetter.typeset(#"x = 1 \text{ if } x > 0"#, fontSize: 16, display: false).get()
        #expect(formula.width > 0)
        #expect(MicroTeXCallbacks.state.line(for: 1) == nil)
    }

    @Test("Rewrites: \\pmod, \\bmod, / and \\operatorname* match amsmath and leave text alone")
    func compatRewrites() {
        #expect(MicroTeXCompat.rewrite(#"a \equiv b \pmod{p^{2}}"#) == #"a \equiv b \,\;(\mathrm{mod}\,\,p^{2})"#)
        #expect(MicroTeXCompat.rewrite(#"a \bmod n"#) == #"a \mathbin{\mathrm{mod}} n"#)
        #expect(MicroTeXCompat.rewrite("a/b") == "a{/}b")
        #expect(MicroTeXCompat.rewrite(#"\text{and/or} a/b"#) == #"\text{and/or} a{/}b"#)
        #expect(MicroTeXCompat.rewrite(#"\operatorname*{colim}_i"#) == #"\mathop{\mathrm{colim}}\limits_i"#)
        #expect(MicroTeXCompat.rewrite(#"\operatorname{Hom}"#) == #"\operatorname{Hom}"#)
    }

    @Test("A slash is spaced as an ordinary symbol")
    func slashSpacing() throws {
        let rewritten = try typesetter.typeset(MicroTeXCompat.rewrite("a/b"), fontSize: 16, display: false).get()
        let grouped = try typesetter.typeset("a{/}b", fontSize: 16, display: false).get()
        #expect(rewritten.width == grouped.width)
    }
}

@Suite("Drawing-data decoder")
struct DrawOpDecoderTests {
    private func buffer(_ body: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: UInt32(body.count + 4).littleEndian) { Array($0) } + body
    }

    private func f32(_ x: Float) -> [UInt8] { withUnsafeBytes(of: x) { Array($0) } }
    private func i32(_ x: Int32) -> [UInt8] { withUnsafeBytes(of: x) { Array($0) } }

    @Test func decodesAPathAndCachesIt() throws {
        let body: [UInt8] = [10] + i32(7) + [11] + f32(0) + f32(0) + [12] + f32(1) + f32(1) + [15] + [16] + i32(7)
        var cache: [Int32: CGPath] = [:]
        let ops = try buffer(body).withUnsafeBytes { try DrawOpDecoder.decode($0, glyphPaths: &cache, textLine: { _ in nil }) }
        #expect(ops.count == 1)
        #expect(cache[7] != nil)
        // Next time MicroTeX sends only "begin 7, fill 7"; the cached outline is used.
        let reuse: [UInt8] = [10] + i32(7) + [16] + i32(7)
        let again = try buffer(reuse).withUnsafeBytes { try DrawOpDecoder.decode($0, glyphPaths: &cache, textLine: { _ in nil }) }
        #expect(again.count == 1)
    }

    @Test("Unknown commands, truncation and missing paths fail instead of drawing part of a formula")
    func failsLoudly() {
        var cache: [Int32: CGPath] = [:]
        for body in [[99] as [UInt8], [5] + f32(1), [10] + i32(3) + [16] + i32(3), [9, 0, 0]] {
            #expect(throws: DrawOpDecodingError.self) {
                try buffer(body).withUnsafeBytes { try DrawOpDecoder.decode($0, glyphPaths: &cache, textLine: { _ in nil }) }
            }
        }
    }
}

@Suite("Renderer")
struct MathRendererTests {
    private let renderer = MathRenderer.standard()

    @Test func routesEachFormulaToTheRightTier() {
        let context = MathContext()
        #expect(renderer.render("q > p", context: context, style: .inline).tierName == "typographic")
        #expect(renderer.render(#"\frac{p^2-1}{q}"#, context: context, style: .inline).tierName == "engine")
        #expect(renderer.render("q > p", context: context, style: .display).tierName == "engine")
        #expect(renderer.render(#"\nosuchthing"#, context: context, style: .inline).tierName == "source")
    }

    @Test("Invariant 16: a formula is set exactly or shown as its source with a reason")
    func neverApproximates() {
        let context = MathContext()
        for tex in [#"\begin{CD}A@>>>B\end{CD}"#, #"\frac{a"#, #"\nosuchthing{x}"#, "   "] {
            guard case .source(let chip) = renderer.render(tex, context: context, style: .display) else {
                Issue.record("\(tex) was rendered")
                continue
            }
            #expect(chip.latex == tex)
            #expect(!chip.message.isEmpty)
        }
    }

    @Test func macrosApplyBeforeEitherTier() {
        let macros = MacroSet(MacroParser.parse(#"\newcommand{\Z}{\mathbb{Z}}\newcommand{\abs}[1]{\lvert #1\rvert}"#).definitions)
        let context = MathContext(macros: macros)
        guard case .typographic(let runs) = renderer.render(#"\Z/p\Z"#, context: context, style: .inline) else {
            Issue.record("expected tier 1")
            return
        }
        #expect(plain(runs) == "ℤ/pℤ")
        #expect(renderer.render(#"\abs{\frac{a}{b}}"#, context: context, style: .inline).tierName == "engine")
    }

    @Test("A starred operator from the registry goes to the engine, never shows a stray *")
    func starredOperatorMacro() {
        let macros = MacroSet(MacroParser.parse(#"\DeclareMathOperator*{\colim}{colim}"#).definitions)
        #expect(renderer.render(#"\colim_i F_i"#, context: MathContext(macros: macros), style: .inline).tierName == "engine")
    }

    @Test func aMacroErrorBecomesASourceChip() {
        let macros = MacroSet(MacroParser.parse(#"\newcommand{\a}{\a\a}"#).definitions)
        guard case .source(let chip) = renderer.render(#"\a"#, context: MathContext(macros: macros), style: .inline) else {
            Issue.record("expected a source chip")
            return
        }
        #expect(chip.message.contains("terminate"))
    }

    @Test func cachesByMacrosSizeAndStyle() {
        let renderer = MathRenderer.standard()
        let context = MathContext()
        _ = renderer.render("x^2", context: context, style: .inline)
        _ = renderer.render("x^2", context: context, style: .inline)
        #expect(renderer.cacheHits == 1)
        _ = renderer.render("x^2", context: MathContext(fontSize: 20), style: .inline)
        _ = renderer.render("x^2", context: context, style: .display)
        let macros = MacroSet(MacroParser.parse(#"\newcommand{\x}{y}"#).definitions)
        _ = renderer.render("x^2", context: MathContext(macros: macros), style: .inline)
        #expect(renderer.cacheHits == 1)
    }

    @Test func generationalCacheKeepsRecentEntries() {
        var cache = GenerationalCache<Int, Int>(capacity: 2)
        cache[1] = 1; cache[2] = 2; cache[3] = 3   // 1 and 2 move to the old generation
        #expect(cache[1] == 1)                     // promoted
        cache[4] = 4; cache[5] = 5                 // the old generation (holding 2) is dropped
        #expect(cache[2] == nil)
        #expect(cache[1] == 1)
    }
}

@Suite("Structural validation")
struct TeXValidatorTests {
    @Test(arguments: [#"\frac{a"#, #"\frac{a}"#, "a}", #"\left( x"#, #"x \right)"#, #"\begin{cases} a"#,
                      #"\begin{cases}a\end{array}"#, #"\sqrt"#, #"\sqrt[3]"#, #"\mathbb"#, #"\overset{a}"#])
    func rejectsBrokenStructure(_ tex: String) {
        #expect(TeXValidator.problem(in: tex) != nil)
    }

    @Test("Definitions inside a formula are refused: they would change later formulas")
    func definitionsBelongInTheRegistry() {
        for tex in [#"\newcommand{\x}{y} \x"#, #"\renewcommand{\vec}{v}"#, #"\def\a{b}"#, #"\DeclareMathOperator{\Hom}{Hom}"#] {
            #expect(TeXValidator.problem(in: tex)?.contains("notation registry") == true, "\(tex)")
        }
    }

    @Test func reportsTheActualProblem() {
        #expect(TeXValidator.problem(in: #"\frac{a"#) == "An opening brace is never closed")
        #expect(TeXValidator.problem(in: #"\frac{a}"#) == "\\frac is missing argument 2 of 2")
    }

    @Test(arguments: [#"\frac{a}{b}"#, #"\sqrt[3]{x}"#, #"\left( \frac{p}{q} \right)"#, #"\frac12"#,
                      #"\begin{pmatrix} a & b \end{pmatrix}"#, #"\operatorname*{colim}_i F(i)"#, "x^2", #"\xrightarrow[a]{b}"#])
    func acceptsSoundStructure(_ tex: String) {
        #expect(TeXValidator.problem(in: tex) == nil)
    }
}

@Suite("Prose segmentation")
struct ProseSegmenterTests {
    @Test func splitsInlineAndDisplayMath() {
        #expect(ProseSegmenter.segments("If $q>p$ then $$x$$ and \\(y\\) or \\[z\\].") == [
            .text("If "), .math("q>p", .inline), .text(" then "), .math("x", .display), .text(" and "),
            .math("y", .inline), .text(" or "), .math("z", .display), .text("."),
        ])
    }

    @Test func escapedDollarsAndUnterminatedMath() {
        #expect(ProseSegmenter.segments(#"costs \$5"#) == [.text("costs $5")])
        #expect(ProseSegmenter.segments("let $x be") == [.text("let "), .unterminated("$x be")])
    }

    @Test("An unterminated formula shows as a source chip, not as prose")
    func unterminatedIsAProblem() {
        let composed = MathTextComposer.compose("let $x be", renderer: MathRenderer.standard(), context: MathContext())
        #expect(composed.problems.count == 1)
    }
}

@Suite("Accessibility of math")
struct MathAccessibilityTests {
    @Test("VoiceOver hears scripts and source chips")
    func spokenText() {
        let composed = MathTextComposer.compose(#"Then $n_p = q$ and $|G| = p^2 q$; but $\frac{a$."#,
                                                renderer: MathRenderer.standard(), context: MathContext())
        #expect(composed.accessibilityText.contains("n sub p"))
        #expect(composed.accessibilityText.contains("p superscript 2"))
        #expect(composed.accessibilityText.contains("formula shown as source"))
    }
}

@Suite("Tier 2 text fallback", .serialized)
struct MicroTeXTextFallbackTests {
    @Test("Glyphs the math font lacks go through text layout with the right height")
    func textFallbackMetrics() throws {
        let formula = try MicroTeXTypesetter.shared.typeset(#"\text{日本}"#, fontSize: 16, display: false).get()
        #expect(formula.ops.contains { if case .text = $0 { true } else { false } })
        #expect(formula.ascent > 8, "a negative ascent from the callback would collapse the box")
        #expect(formula.descent >= 0)
    }
}
