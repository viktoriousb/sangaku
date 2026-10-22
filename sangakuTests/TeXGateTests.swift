import Foundation
import Testing
@testable import sangaku

@Suite("Export: the TeX gate")
struct TeXGateTests {
    private static let macros = MacroSet(MacroParser.parse(#"""
        \newcommand{\abs}[1]{\lvert #1 \rvert}
        \DeclareMathOperator{\Syl}{Syl}
        \newcommand{\Z}{\mathbb{Z}}
        """#).definitions)

    /// Every formula in `text` counted as set by the app.
    static func rendered(_ texts: String...) -> FormulaVerdicts { FormulaVerdicts(texts: texts) { _, _ in nil } }

    private func prose(_ text: String) throws(TeXRefusal) -> String {
        try TeXGate.prose(text, macros: Self.macros, verdicts: Self.rendered(text)).source
    }

    private func refusal(_ text: String) -> TeXRefusal? {
        do {
            _ = try prose(text)
            return nil
        } catch {
            return error
        }
    }

    @Test("Text is printed as typed: every special character is escaped, and commands in text are never run")
    func text() throws {
        #expect(try TeXGate.plain(#"50% & #1 a_b x^2 ~y {z} \input{x} $5 <a> [b]"#).source
                == ##"50\% \& \#1 a\_b x\textasciicircum{}2 \textasciitilde{}y \{z\} \textbackslash{}input\{x\} \$5 \textless{}a\textgreater{} {[}b{]}"##)
        #expect(try TeXGate.plain("a--b, ''q'' ,,x `y").source == "a-{}-b, '{}'q'{}' ,{},x \\textasciigrave{}y")
        #expect(try TeXGate.plain("two\n  lines\t here").source == "two lines here")
        #expect(try TeXGate.plain(" over ").source == " over ", "pieces keep the spaces that join them")
        #expect(try prose("Line one.\n\nLine two.") == "Line one.\n\nLine two.")
    }

    @Test("Unicode: Latin letters pass, mathematical signs are set, anything else is refused by name")
    func unicode() throws {
        #expect(try TeXGate.plain("Théorèmes, Gödel, Łukasiewicz – “quoted” …").source
                == "Théorèmes, Gödel, Łukasiewicz – “quoted” …")
        #expect(try TeXGate.plain("p²q ≤ 100, n₃ = 4, α ∈ ℤ").source
                == #"p\textsuperscript{2}q \ensuremath{\le} 100, n\textsubscript{3} = 4, \ensuremath{\alpha} \ensuremath{\in} \ensuremath{\mathbb{Z}}"#)
        #expect(try prose("$p ≠ q$, $n₃ = 4$, $x ∈ G$, $p²³$") == #"$p \ne  q$, $n_{3} = 4$, $x \in  G$, $p^{23}$"#)
        #expect(throws: TeXRefusal.character("😀")) { try TeXGate.plain("ok 😀") }
        #expect(throws: TeXRefusal.character("ж")) { try TeXGate.plain("ж") }
        #expect(throws: TeXRefusal.hidden("\u{202E}")) { try TeXGate.plain("a\u{202E}b") }
        #expect(throws: TeXRefusal.character("é")) { try prose("$é$") }
        #expect(try prose(#"$\text{für alle } x$"#) == #"$\text{für alle } x$"#, "text inside a formula keeps its letters")
    }

    @Test("Mathematics passes as written when every command is on the list or the problem's macro")
    func mathematics() throws {
        #expect(try prose(#"Let $p \neq q$ and $\abs{G} = p^2 q$; $\Syl_p(G)$ and $\Z/n\Z$."#)
                == #"Let $p \neq q$ and $\abs{G} = p^2 q$; $\Syl_p(G)$ and $\Z/n\Z$."#)
        #expect(try prose(#"$$\sum_{k=0}^{n} \binom{n}{k} = 2^n$$ and \[ \begin{pmatrix} a & b \\ c & d \end{pmatrix} \]"#)
                == #"\[\sum_{k=0}^{n} \binom{n}{k} = 2^n\] and \[ \begin{pmatrix} a & b \\ c & d \end{pmatrix} \]"#)
        #expect(try prose(#"$a \lt b \gt c$"#) == "$a < b > c$", "\\lt and \\gt are rewritten exactly")
        #expect(try prose(#"$\sum_{\substack{i < j \\ i, j \in I}} a_{ij}$"#).contains(#"\\ i, j"#))
        #expect(try prose(#"$\begin{array}{c|c} a & b \\ \hline c & d \end{array}$"#).contains("{c|c}"))
        #expect(try prose("$\\%$ and $\\#$ and $\\$$") == "$\\%$ and $\\#$ and $\\$$")
    }

    @Test("Anything that reads, writes, redefines or structures is refused, naming it", arguments: [
        (#"$\input{secret}$"#, TeXRefusal.command("input")), (#"$\include{x}$"#, .command("include")),
        (#"$\write18{rm}$"#, .command("write")), (#"$\immediate\write$"#, .command("immediate")),
        (#"$\openin1=x$"#, .command("openin")), (#"$\read1 to\x$"#, .command("read")),
        (#"$\catcode`\%=12$"#, .command("catcode")), (#"$\csname input\endcsname$"#, .command("csname")),
        (#"$\expandafter x$"#, .command("expandafter")), (#"$\special{x}$"#, .command("special")),
        (#"$\usepackage{x}$"#, .command("usepackage")), (#"$\iffalse x \fi$"#, .command("iffalse")),
        (#"$\section{x}$"#, .command("section")), (#"$\label{x}$"#, .command("label")),
        (#"$\ref{x}$"#, .command("ref")), (#"$\color{red}{x}$"#, .command("color")),
        (#"$\begin{comment} x \end{comment}$"#, .environment("comment")),
        (#"$\begin{CD} A @>>> B \end{CD}$"#, .environment("CD")),
        (#"$a \( b \)$"#, .symbol("(")), (#"$\@ x$"#, .symbol("@")),
        (#"$x^^5cinput{foo}$"#, .structure(TeXGate.doubleCaret)), (#"$\text{^^5cinput{x}}$"#, .structure(TeXGate.doubleCaret)),
        (#"$a^^25 b$"#, .structure(TeXGate.doubleCaret)), (#"$x^²$"#, .structure(TeXGate.doubleCaret)),
    ])
    func refusals(text: String, expected: TeXRefusal) {
        #expect(refusal(text) == expected, "\(text)")
    }

    @Test("Definitions are refused before anything else looks at them")
    func definitions() {
        for text in [#"$\def\x{y}$"#, #"$\newcommand{\x}{y}$"#, #"$\let\x\y$"#] {
            guard case .structure(let message) = refusal(text) else {
                Issue.record("\(text) was not refused as a definition")
                continue
            }
            #expect(message.contains("notation registry"))
        }
    }

    @Test("Characters that end a line, an argument or the formula are refused bare")
    func bareSpecials() {
        for text in ["$50%$", "$#1$", #"\(a $ b\)"#, "$a & b$", #"$a \\ b$"#] {
            guard case .structure = refusal(text) else {
                Issue.record("\(text) was not refused")
                continue
            }
        }
        #expect(refusal("$x") == .unterminated)
        #expect(refusal("$ $") == .structure("a formula is empty"))
    }

    @Test("Invariant 16: a formula the app shows as its source is refused, never exported as mathematics")
    func unrendered() throws {
        let text = #"Bad $\frac{a$ and good $x$."#
        let verdicts = FormulaVerdicts(texts: [text]) { latex, _ in latex.contains("frac") ? "An opening brace is never closed" : nil }
        #expect(throws: TeXRefusal.unrendered("An opening brace is never closed")) {
            try TeXGate.prose(text, macros: .empty, verdicts: verdicts)
        }
        #expect(try TeXGate.prose("Good $x$.", macros: .empty, verdicts: verdicts).source == "Good $x$.")
        #expect(throws: TeXRefusal.unrendered("the app did not check it"), "a formula never shown to the renderer fails closed") {
            try TeXGate.prose("Unseen $y$.", macros: .empty, verdicts: verdicts)
        }
    }

    @Test("Notation: each macro is provided, then renewed; bodies pass the gate; the document's names are refused")
    func notation() throws {
        let parse = { (source: String) in MacroParser.parse(source).definitions[0] }
        #expect(try TeXGate.macro(parse(#"\newcommand{\abs}[1]{\lvert #1 \rvert}"#), macros: Self.macros).source
                == #"\providecommand{\abs}{}\renewcommand{\abs}[1]{\lvert #1 \rvert}"#)
        #expect(try TeXGate.macro(parse(#"\DeclareMathOperator*{\colim}{colim}"#), macros: Self.macros).source
                == #"\providecommand{\colim}{}\renewcommand{\colim}{\operatorname*{colim}}"#)
        #expect(try TeXGate.macro(parse(#"\newcommand{\N}{\mathbb{N}}"#), macros: Self.macros).source
                == #"\providecommand{\N}{}\renewcommand{\N}{\mathbb{N}}"#, "the kit's own \\N is replaced, not clashed with")
        #expect(throws: TeXRefusal.macroName("input")) { try TeXGate.macro(parse(#"\newcommand{\input}{x}"#), macros: .empty) }
        #expect(throws: TeXRefusal.macroName("endproof")) { try TeXGate.macro(parse(#"\newcommand{\endproof}{x}"#), macros: .empty) }
        #expect(throws: TeXRefusal.macroName("htagsalt")) { try TeXGate.macro(parse(#"\newcommand{\htagsalt}{x}"#), macros: .empty) }
        #expect(throws: TeXRefusal.command("write")) { try TeXGate.macro(parse(#"\newcommand{\x}{\write18}"#), macros: .empty) }
        #expect(throws: TeXRefusal.self) { try TeXGate.macro(parse(#"\newcommand{\x}[1]{#2}"#), macros: .empty) }
        #expect(throws: TeXRefusal.operatorText) {
            try TeXGate.macro(MacroDefinition(name: "Op", arity: 0, body: #"\input x"#, kind: .operatorName), macros: .empty)
        }
    }

    @Test("Labels come from the kind and the stable ID only; links only with plain characters")
    func labelsAndLinks() throws {
        let id = try #require(UUID(uuidString: "1A2B3C4D-5E6F-4071-8293-A4B5C6D7E8F9"))
        #expect(TeXGate.label(.lemma, id).source == "lem:s1a2b3c4d5e6f")
        #expect(TeXGate.label(.claim, id).source == "clm:s1a2b3c4d5e6f")
        #expect(TeXGate.citationKey(id).source == "cit1a2b3c4d5e6f")
        #expect(TeXGate.url(try #require(URL(string: "https://zbmath.org/?q=an:0712.20001")))?.source
                == #"\url{https://zbmath.org/?q=an:0712.20001}"#)
        #expect(TeXGate.url(try #require(URL(string: "https://zbmath.org/a%20b"))) == nil)
        #expect(TeXGate.url(try #require(URL(string: "http://zbmath.org/x"))) == nil)
    }

    @Test("The formula corpus: each formula is exported, or refused with the command or environment named")
    func corpus() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Corpus")
        let macros = MacroSet(MacroParser.parse(try String(contentsOf: folder.appending(path: "corpus-preamble.tex"),
                                                           encoding: .utf8)).definitions)
        var refused: [String: TeXRefusal] = [:]
        var exported = 0
        for line in try String(contentsOf: folder.appending(path: "formulas.tsv"), encoding: .utf8).split(separator: "\n")
        where !line.hasPrefix("#") {
            let latex = String(line.split(separator: "\t", maxSplits: 2)[2])
            do {
                _ = try TeXGate.math(latex, macros: macros)
                exported += 1
            } catch {
                refused[latex] = error
            }
        }
        #expect(Set(refused.values) == [.command("color"), .environment("CD")], "\(refused)")
        #expect(exported >= 79)
    }

    @Test("Property: whatever the gate accepts uses only listed commands, no bare %, # or $, and balanced braces",
          arguments: 0..<20)
    func fuzz(seed: Int) {
        var random = SeededGenerator(state: UInt64(seed) &* 7919)
        let pieces = [#"\input"#, #"\write"#, "{", "}", "$", "$$", #"\("#, #"\)"#, #"\["#, #"\]"#, "%", "#", "&", "^",
                      "_", "~", #"\\"#, #"\frac"#, #"\text{"#, #"\begin{pmatrix}"#, #"\end{pmatrix}"#, #"\abs"#,
                      #"\catcode"#, #"\csname"#, "a", "x", " ", "\n", "é", "²", "≤", "😀", #"\alpha"#, #"\%"#, #"\$"#,
                      #"\left("#, #"\right)"#, #"\lt"#, "@", "'", "--", "[", "]", #"\def"#, #"\iffalse"#,
                      "^^5c", "^^25", "^^7d", "^", "²", "₃"]
        var accepted = 0
        for _ in 0..<250 {
            let text = (0..<Int.random(in: 1...12, using: &random)).map { _ in pieces.randomElement(using: &random) ?? "" }
                .joined()
            guard let output = try? prose(text) else { continue }
            accepted += 1
            #expect(TeXOutputAudit.problem(in: output, macros: Self.macros) == nil, "\(text) gave \(output)")
        }
        #expect(accepted > 0)
    }

    @Test("Only the gate makes a fragment from text")
    func scan() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "sangaku")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found = Set<String>()
        for case let url as URL in files where url.pathExtension == "swift" {
            if try String(contentsOf: url, encoding: .utf8).contains("TeXFragment(gated:") { found.insert(url.lastPathComponent) }
        }
        #expect(found == ["TeXGate.swift"])
    }
}

/// An independent reading of what the gate wrote: it re-lexes the output instead of trusting the gate's own walk.
enum TeXOutputAudit {
    /// Commands the gate writes for text.
    static let escapes: Set<String> = [
        "textbackslash", "textasciicircum", "textasciitilde", "textless", "textgreater", "textasciigrave",
        "textsuperscript", "textsubscript", "ensuremath",
    ]

    static func problem(in output: String, macros: MacroSet) -> String? {
        var depth = 0
        var dollars = 0
        var previousBackslash = false
        for character in output {
            if previousBackslash {
                previousBackslash = false
                continue
            }
            switch character {
            case "\\": previousBackslash = true
            case "{": depth += 1
            case "}": depth -= 1; if depth < 0 { return "a closing brace too many" }
            case "%": return "a bare %"
            case "#": return "a bare #"
            case "$": dollars += 1
            default: break
            }
        }
        if depth != 0 { return "unbalanced braces" }
        if output.contains("^^") { return "TeX's ^^ notation" }
        if dollars % 2 != 0 { return "an odd number of $" }
        for token in TeXLexer.tokens(output) {
            guard case .command(let name) = token else { continue }
            if !(TeXTables.mathCommands.contains(name) || escapes.contains(name) || macros.definitions[name] != nil) {
                return "\\\(name) is not listed"
            }
        }
        return nil
    }
}
