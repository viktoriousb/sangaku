import Foundation
import Testing
@testable import sangaku

@Suite("TeX tokenizer")
struct TeXLexerTests {
    @Test func tokenizesWordsSymbolsAndGroups() throws {
        let tokens = TeXLexer.tokens(#"\frac{a}{b}\,x"#)
        #expect(tokens == [.command("frac"), .open, .char("a"), .close, .open, .char("b"), .close, .symbol(","), .char("x")])
    }

    @Test func rebuildingNeverFusesAControlWordWithALetter() throws {
        let tokens: [TeXToken] = [.command("alpha"), .char("x")]
        #expect(TeXLexer.string(tokens) == #"\alpha x"#)
        #expect(TeXLexer.string(TeXLexer.tokens(#"\alpha{x}"#)) == #"\alpha{x}"#)
    }

    @Test func commentsAreStrippedOnlyWhenAsked() throws {
        #expect(TeXLexer.tokens("a % note\nb", stripComments: true) == [.char("a"), .space(" "), .space("\n"), .char("b")]
            || TeXLexer.string(TeXLexer.tokens("a % note\nb", stripComments: true)) == "a \nb")
        #expect(TeXLexer.tokens(#"50\%"#, stripComments: true).last == .symbol("%"))
        #expect(TeXLexer.tokens("5%", stripComments: false).last == .char("%"))
    }

    @Test("Windows line ends: comments end at the line, and lines are counted")
    func crlf() throws {
        let located = TeXLexer.tokensWithLines("% note\r\n\\Z\r\n", stripComments: true)
        #expect(located.first { $0.token == .command("Z") }?.line == 2)
        let parsed = MacroParser.parse("% packages\r\n\\newcommand{\\Z}{\\mathbb{Z}}\r\n\\def\\N{x}\r\n")
        #expect(parsed.definitions.map(\.name) == ["Z"])
        #expect(parsed.skipped.first?.line == 3)
        #expect(parsed.skipped.first?.text == #"\def\N{x}"#)
    }

    @Test func linesAreTracked() throws {
        let located = TeXLexer.tokensWithLines("a\n\\b\n\nc")
        #expect(located.first { $0.token == .command("b") }?.line == 2)
        #expect(located.first { $0.token == .char("c") }?.line == 4)
    }

    @Test func groupsAndArgumentsRespectNesting() throws {
        let tokens = TeXLexer.tokens("{a{b}c}d")
        let group = tokens.group(at: 0)
        #expect(group?.contents == TeXLexer.tokens("a{b}c"))
        #expect(group?.end == tokens.count - 1)
        #expect(tokens.argument(at: group!.end)?.contents == [.char("d")])
    }
}

@Suite("Macros")
struct MacroSetTests {
    private func macros(_ preamble: String) -> MacroSet { MacroSet(MacroParser.parse(preamble).definitions) }

    @Test func expandsArgumentsAndNestedMacros() throws {
        let set = macros(#"""
        \newcommand{\Z}{\mathbb{Z}}
        \newcommand{\abs}[1]{\lvert #1 \rvert}
        \newcommand{\quot}[2]{#1/#2}
        """#)
        #expect(try set.expand(#"\abs{G}"#).get() == #"\lvert G \rvert"#)
        #expect(try set.expand(#"\quot{\Z}{n\Z}"#).get() == #"\mathbb{Z}/n\mathbb{Z}"#)
    }

    @Test func expansionNeverFusesWithFollowingLetters() throws {
        let set = macros(#"\newcommand{\eps}{\varepsilon}"#)
        #expect(try set.expand(#"\eps x"#).get() == #"\varepsilon x"#)
    }

    @Test func operatorsExpandToOperatorname() throws {
        let set = macros(#"\DeclareMathOperator{\Hom}{Hom}\DeclareMathOperator*{\colim}{colim}"#)
        #expect(try set.expand(#"\Hom(M,N)"#).get() == #"\operatorname{Hom}(M,N)"#)
        #expect(try set.expand(#"\colim_i"#).get() == #"\operatorname*{colim}_i"#)
    }

    @Test func runawayDefinitionsStopWithAnError() throws {
        let set = macros(#"\newcommand{\a}{\a\a}"#)
        #expect(throws: MacroError.self) { try set.expand(#"\a"#).get() }
        let selfReference = macros(#"\newcommand{\b}{x\b}"#)
        #expect(throws: MacroError.self) { try selfReference.expand(#"\b"#).get() }
    }

    @Test func aMissingArgumentIsAnError() throws {
        let set = macros(#"\newcommand{\pair}[2]{(#1,#2)}"#)
        #expect(throws: MacroError.self) { try set.expand(#"\pair{a}"#).get() }
    }

    @Test func fingerprintIgnoresOrderButNotContent() throws {
        let a = macros(#"\newcommand{\Z}{\mathbb{Z}}\newcommand{\Q}{\mathbb{Q}}"#)
        let b = macros(#"\newcommand{\Q}{\mathbb{Q}}\newcommand{\Z}{\mathbb{Z}}"#)
        let c = macros(#"\newcommand{\Z}{\mathbf{Z}}\newcommand{\Q}{\mathbb{Q}}"#)
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.fingerprint != c.fingerprint)
        #expect(MacroSet.empty.expand(#"\Z"#) == .success(#"\Z"#))
    }
}

@Suite("Preamble parsing")
struct MacroParserTests {
    @Test func readsTheCommonForms() throws {
        let result = MacroParser.parse(#"""
        % number systems
        \newcommand{\Z}{\mathbb{Z}}
        \newcommand\Q{\mathbb{Q}}
        \newcommand*{\abs}[1]{\lvert #1\rvert}
        \renewcommand{\epsilon}{\varepsilon}
        \providecommand{\R}{\mathbb{R}}
        \providecommand{\R}{\mathbf{R}}
        \DeclareMathOperator{\Hom}{Hom}
        \DeclareMathOperator*{\colim}{colim}
        \usepackage{amsmath}
        """#)
        let names = result.definitions.map(\.name)
        #expect(names == ["Z", "Q", "abs", "epsilon", "R", "Hom", "colim"])
        #expect(result.definitions.first { $0.name == "R" }?.body == #"\mathbb{R}"#)
        #expect(result.definitions.first { $0.name == "abs" }?.arity == 1)
        #expect(result.definitions.first { $0.name == "colim" }?.kind == .operatorNameWithLimits)
        #expect(result.skipped.isEmpty)
    }

    @Test func unsupportedDefinitionsAreReportedWithLineAndReason() throws {
        let result = MacroParser.parse(#"""
        \def\N{\mathbb{N}}
        \newcommand{\Z}{\mathbb{Z}}
        \newcommand{\norm}[2][2]{\|#2\|_{#1}}
        \newcommand{\Q}{\mathbb{Q}}
        """#)
        #expect(result.definitions.map(\.name) == ["Z", "Q"])
        #expect(result.skipped.map(\.line) == [1, 3])
        #expect(result.skipped[0].reason.contains("\\def"))
        #expect(result.skipped[1].reason.contains("default"))
    }

    @Test("\\providecommand leaves LaTeX's own commands alone, and robust commands are reported")
    func builtInsAndRobustCommands() throws {
        let result = MacroParser.parse(#"\providecommand{\vec}{v}\providecommand{\R}{\mathbb{R}}\DeclareRobustCommand{\x}{y}"#)
        #expect(result.definitions.map(\.name) == ["R"])
        #expect(result.skipped.count == 2)
        #expect(result.skipped[0].reason.contains("already defined"))
        #expect(result.skipped[1].reason.contains("DeclareRobustCommand"))
    }

    @Test func aBadLineDoesNotDropTheRest() throws {
        let result = MacroParser.parse("\\newcommand{oops}\n\\newcommand{\\Z}{\\mathbb{Z}}")
        #expect(result.definitions.map(\.name) == ["Z"])
        #expect(result.skipped.count == 1)
    }

    @Test func canonicalSourceRoundTrips() throws {
        for source in [#"\newcommand{\abs}[1]{\lvert #1\rvert}"#, #"\DeclareMathOperator*{\colim}{colim}"#, #"\newcommand{\Z}{\mathbb{Z}}"#] {
            let definition = MacroParser.parse(source).definitions[0]
            #expect(definition.canonicalSource == source)
            #expect(MacroParser.parse(definition.canonicalSource).definitions == [definition])
        }
    }
}
