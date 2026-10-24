import Foundation

/// TeX an export may write. Made only from a literal in the app's source (`StaticString`: no interpolation, so no
/// text from the store) or by `TeXGate`, whose initializer is private to this file. Writers only join fragments, so
/// no text reaches a `.tex` or `.bib` file without passing the gate.
nonisolated struct TeXFragment: Hashable, Sendable, ExpressibleByStringLiteral {
    let source: String

    init(stringLiteral value: StaticString) {
        source = value.description
    }

    fileprivate init(gated source: String) {
        self.source = source
    }

    /// A number: digits and a sign, nothing TeX reads otherwise.
    init(_ number: Int) {
        source = String(number)
    }

    static let empty: TeXFragment = ""

    var isEmpty: Bool { source.isEmpty }

    static func + (lhs: TeXFragment, rhs: TeXFragment) -> TeXFragment {
        TeXFragment(gated: lhs.source + rhs.source)
    }

    static func += (lhs: inout TeXFragment, rhs: TeXFragment) {
        lhs = lhs + rhs
    }

    static func joined(_ parts: [TeXFragment], separator: TeXFragment = .empty) -> TeXFragment {
        TeXFragment(gated: parts.map(\.source).joined(separator: separator.source))
    }
}

/// Why the gate refused a text. Every refusal names what it refused.
nonisolated enum TeXRefusal: Error, Hashable, Sendable {
    case command(String)
    case environment(String)
    case symbol(Character)
    case character(Character)
    case hidden(Unicode.Scalar)
    /// The app shows this formula as its source, with this reason (invariant 16).
    case unrendered(String)
    case unterminated
    case structure(String)
    case tooLong
    case macroName(String)
    case operatorText

    var message: String {
        switch self {
        case .command(let name): "\\\(name) is not among the commands an export writes"
        case .environment(let name): "the environment \(name) is not among those an export writes"
        case .symbol(let symbol): "\\\(symbol) is not allowed in a formula"
        case .character(let character):
            "\(character.unicodeScalars.first.map(CodeText.name) ?? "a character") (\(character)) cannot be set by pdfLaTeX here"
        case .hidden(let scalar): "it holds an invisible or control character (\(CodeText.name(scalar)))"
        case .unrendered(let reason): "the app shows a formula as its source (\(reason)), so it is not exported as mathematics"
        case .unterminated: "a formula is opened but never closed"
        case .structure(let what): what
        case .tooLong: "it is too long to export"
        case .macroName(let name): "the macro name \\\(name) is used by the document itself"
        case .operatorText: "an operator's name may hold only letters, digits, spaces and . - '"
        }
    }
}

/// Where a refused text is, as a person finds it in the app.
nonisolated enum TeXLocation: Hashable, Sendable {
    case title
    case statement(String)
    case status(String)
    case refutation(String)
    case importedSource(String)
    /// A step by its number, and its attempt when the export holds several.
    case step(Int, attempt: Int?)
    case establishes(Int, attempt: Int?)
    case citation(Int, attempt: Int?)
    case notation(String)
    case aiUse

    var words: String {
        switch self {
        case .title: "The problem's title"
        case .statement(let label): "The statement of \(label)"
        case .status(let label): "The status of \(label)"
        case .refutation(let label): "The refutation of \(label)"
        case .importedSource(let label): "The source of \(label)"
        case .step(let index, let attempt): "Step \(index)" + (attempt.map { " of attempt \($0)" } ?? "")
        case .establishes(let index, let attempt):
            "What step \(index)" + (attempt.map { " of attempt \($0)" } ?? "") + " establishes"
        case .citation(let index, let attempt): "A citation of step \(index)" + (attempt.map { " of attempt \($0)" } ?? "")
        case .notation(let name): "The notation \\\(name)"
        case .aiUse: "The AI-use statement"
        }
    }
}

/// One text an export cannot write, and where it is.
nonisolated struct ExportRefusal: Hashable, Sendable {
    var location: TeXLocation
    var refusal: TeXRefusal

    var message: String { location.words + ": " + refusal.message + "." }
}

/// What the app's renderer made of every formula an export holds, read on the main actor and handed to the gate as
/// data. A formula shown as its source is refused (invariant 16); so is one the renderer was never asked about, so a
/// text left out of the reading fails closed.
nonisolated struct FormulaVerdicts: Hashable, Sendable {
    nonisolated enum Verdict: Hashable, Sendable {
        case rendered
        case source(String)
        case unchecked
    }

    private var rendered: Set<String> = []
    private var unrendered: [String: String] = [:]

    init() {}

    /// Asks `reason` about every formula in `texts`: nil if the app sets it, else why it shows the source.
    init(texts: [String], reason: (String, MathStyle) -> String?) {
        for text in texts {
            for case .math(let latex, let style) in ProseSegmenter.segments(text.precomposedStringWithCanonicalMapping) {
                let key = Self.key(latex, style)
                guard !rendered.contains(key), unrendered[key] == nil else { continue }
                if let reason = reason(latex, style) { unrendered[key] = reason } else { rendered.insert(key) }
            }
        }
    }

    private static func key(_ latex: String, _ style: MathStyle) -> String {
        (style == .display ? "d:" : "i:") + latex
    }

    func verdict(_ latex: String, _ style: MathStyle) -> Verdict {
        let key = Self.key(latex, style)
        if let reason = unrendered[key] { return .source(reason) }
        return rendered.contains(key) ? .rendered : .unchecked
    }
}

/// The one boundary between the store's text and TeX. Text is printed as itself, never run: every special
/// character is escaped and every non-ASCII character is set or refused. Mathematics is allow-listed: every
/// command and environment must be on `TeXTables`' lists or be one of the problem's macros, whose bodies pass the
/// same gate. Nothing that reads, writes or redefines (`\input`, `\write`, `\catcode`, `\def`, …) is on a list.
nonisolated enum TeXGate {
    static let maximumLength = 100_000
    static let maximumFormulaTokens = 20_000

    /// One line of plain text (a label, a source, an author): printed as typed, with runs of whitespace as one space.
    static func plain(_ text: String) throws(TeXRefusal) -> TeXFragment {
        TeXFragment(gated: try escape(oneLine(text)))
    }

    /// Prose with mathematics: text printed as typed, mathematics allow-listed. A formula the app shows as its
    /// source is refused (invariant 16).
    static func prose(_ text: String, macros: MacroSet, verdicts: FormulaVerdicts) throws(TeXRefusal) -> TeXFragment {
        guard text.utf8.count <= maximumLength else { throw .tooLong }
        var out = ""
        for segment in ProseSegmenter.segments(text.precomposedStringWithCanonicalMapping) {
            switch segment {
            case .text(let words):
                out += try escape(words)
            case .math(let latex, let style):
                switch verdicts.verdict(latex, style) {
                case .rendered: break
                case .source(let reason): throw .unrendered(reason)
                case .unchecked: throw .unrendered("the app did not check it")
                }
                let body = try math(latex, macros: macros)
                out += style == .display ? "\\[" + body + "\\]" : "$" + body + "$"
            case .unterminated:
                throw .unterminated
            }
        }
        return TeXFragment(gated: out)
    }

    /// One macro of the notation, as `\providecommand{\x}{}\renewcommand{\x}[n]{…}`: it is defined whether or not
    /// LaTeX or the kit already has the name, and means what the notation says. Its body passes the math gate.
    static func macro(_ definition: MacroDefinition, macros: MacroSet) throws(TeXRefusal) -> TeXFragment {
        let name = definition.name
        guard name.count <= 40, name.allSatisfy({ $0.isASCII && $0.isLetter }),
              !TeXTables.protectedMacroNames.contains(name),
              !TeXTables.protectedMacroPrefixes.contains(where: { name.hasPrefix($0) }) else { throw .macroName(name) }
        guard (0...9).contains(definition.arity) else { throw .structure("a macro takes at most 9 arguments") }
        let body: String
        switch definition.kind {
        case .command:
            body = try math(definition.body, macros: macros, parameters: definition.arity)
        case .operatorName, .operatorNameWithLimits:
            guard !definition.body.isEmpty,
                  definition.body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " .-'".contains($0)) })
            else { throw .operatorText }
            body = (definition.kind == .operatorName ? "\\operatorname{" : "\\operatorname*{") + definition.body + "}"
        }
        let arguments = definition.arity > 0 ? "[\(definition.arity)]" : ""
        return TeXFragment(gated: "\\providecommand{\\\(name)}{}\\renewcommand{\\\(name)}\(arguments){\(body)}")
    }

    /// A statement's label: its kind's prefix and its stable ID, never its position or title, so tags do not move.
    static func label(_ kind: StatementKind, _ id: UUID) -> TeXFragment {
        let prefix = switch kind {
        case .theorem: "thm"
        case .lemma: "lem"
        case .claim: "clm"
        case .conjecture: "conj"
        }
        return TeXFragment(gated: prefix + ":s" + LeanNaming.short(id))
    }

    /// The label of the subsection that holds a statement, and of the counterexample a refuted one gets.
    static func subsectionLabel(_ id: UUID) -> TeXFragment { TeXFragment(gated: "ss:s" + LeanNaming.short(id)) }
    static func counterexampleLabel(_ id: UUID) -> TeXFragment { TeXFragment(gated: "cex:s" + LeanNaming.short(id)) }

    /// A key for a bibliography entry, from a stable ID.
    static func citationKey(_ id: UUID) -> TeXFragment {
        TeXFragment(gated: "cit" + LeanNaming.short(id))
    }

    /// An https link with only characters `\url` takes as they are; nil otherwise.
    static func url(_ url: URL) -> TeXFragment? {
        let text = url.absoluteString
        guard text.hasPrefix("https://"), text.count <= 500,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ":/._-?=&+".contains($0)) }) else { return nil }
        return TeXFragment(gated: "\\url{" + text + "}")
    }

    // MARK: Text

    /// Each run of whitespace as one space; a space at either end is kept, so pieces join as written.
    /// A field typeset on one line (the title, what a step establishes, a citation): runs of whitespace as one space,
    /// none at the ends. Its formulas are read in this form, as they will be gated.
    static func line(_ text: String) -> String { oneLine(text).trimmingCharacters(in: .whitespaces) }

    static func oneLine(_ text: String) -> String {
        var out = ""
        var inSpace = false
        for character in text {
            if character.isWhitespace {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(character)
                inSpace = false
            }
        }
        return out
    }

    /// Prints `text` as itself.
    private static func escape(_ text: String) throws(TeXRefusal) -> String {
        guard text.utf8.count <= maximumLength else { throw .tooLong }
        if let scalar = CodeText.hiddenScalar(in: text) { throw .hidden(scalar) }
        var out = ""
        var previous: Character?
        for character in text.precomposedStringWithCanonicalMapping {
            switch character {
            case "\\": out += "\\textbackslash{}"
            case "{", "}", "$", "&", "%", "#", "_": out += "\\" + String(character)
            case "^": out += "\\textasciicircum{}"
            case "~": out += "\\textasciitilde{}"
            case "<": out += "\\textless{}"
            case ">": out += "\\textgreater{}"
            case "`": out += "\\textasciigrave{}"
            case "[", "]": out += "{" + String(character) + "}"
            // Break the ligatures that would print other characters: -- ---, '' and ,,.
            case "-" where previous == "-", "'" where previous == "'", "," where previous == ",":
                out += "{}" + String(character)
            case "\t": out += " "
            default:
                if character.isASCII {
                    out.append(character)
                } else if let form = TeXTables.textForms[character] {
                    out += form
                } else if TeXTables.passesInText(character) {
                    out.append(character)
                } else {
                    throw .character(character)
                }
            }
            previous = character
        }
        return out
    }

    // MARK: Mathematics

    /// The body of a formula, allow-listed, with Unicode set as TeX. `parameters` > 0 only in a macro's body.
    static func math(_ latex: String, macros: MacroSet, parameters: Int = 0) throws(TeXRefusal) -> String {
        let latex = latex.precomposedStringWithCanonicalMapping
        guard latex.utf8.count <= maximumLength else { throw .tooLong }
        if let scalar = CodeText.hiddenScalar(in: latex) { throw .hidden(scalar) }
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .structure("a formula is empty") }
        // TeX reads `^^` followed by a character as another character (`^^5c` is a backslash) before anything else
        // sees it, so it could spell any command the list refuses.
        guard !latex.contains("^^") else { throw .structure(Self.doubleCaret) }
        if let problem = TeXValidator.problem(in: latex) { throw .structure(problem) }
        if parameters == 0 {
            switch macros.expand(latex) {
            case .success(let expanded):
                if let problem = TeXValidator.problem(in: expanded) { throw .structure(problem) }
            case .failure(let error):
                throw .structure(error.message)
            }
        }
        let tokens = TeXLexer.tokens(latex)
        guard tokens.count <= maximumFormulaTokens else { throw .tooLong }

        var out = ""
        var environments: [String] = []
        // Brace depths at which a text argument or a `\substack` argument was opened.
        var textGroups: [Int] = []
        var breakGroups: [Int] = []
        var pending: (text: Bool, breaks: Bool) = (false, false)
        var depth = 0
        var i = 0
        while i < tokens.count {
            let inText = !textGroups.isEmpty
            switch tokens[i] {
            case .command(let name):
                if let rewrite = TeXTables.mathRewrites[name], !macros.definitions.keys.contains(name) {
                    out += rewrite
                    break
                }
                guard TeXTables.mathCommands.contains(name) || macros.definitions[name] != nil else {
                    throw .command(name)
                }
                if name == "begin" || name == "end" {
                    guard let argument = tokens.argument(at: i + 1) else { throw .structure("\\\(name) without an environment") }
                    let environment = TeXLexer.string(argument.contents)
                    guard TeXTables.environments.contains(environment) else { throw .environment(environment) }
                    out += "\\" + name + "{" + environment + "}"
                    i = argument.end
                    if name == "begin" {
                        environments.append(environment)
                        if environment == "array" {
                            guard let columns = tokens.argument(at: i) else { throw .structure("an array without its columns") }
                            let spec = TeXLexer.string(columns.contents)
                            guard !spec.isEmpty, spec.allSatisfy({ "lcr| ".contains($0) }) else {
                                throw .structure("an array's columns may be only l, c, r and |")
                            }
                            out += "{" + spec + "}"
                            i = columns.end
                        }
                    } else {
                        environments.removeLast()
                    }
                    continue
                }
                out += "\\" + name
                pending = (TeXTables.textArguments.contains(name), name == "substack")
            case .symbol(let symbol):
                pending = (false, false)
                if symbol == "\\" {
                    guard !environments.isEmpty || !breakGroups.isEmpty else {
                        throw .structure("a line break \\\\ outside a matrix, an alignment or \\substack")
                    }
                    out += "\\\\"
                } else {
                    guard TeXTables.mathSymbols.contains(symbol) else { throw .symbol(symbol) }
                    out += "\\" + String(symbol)
                }
            case .open:
                depth += 1
                if pending.text { textGroups.append(depth) }
                if pending.breaks { breakGroups.append(depth) }
                pending = (false, false)
                out += "{"
            case .close:
                if textGroups.last == depth { textGroups.removeLast() }
                if breakGroups.last == depth { breakGroups.removeLast() }
                depth -= 1
                out += "}"
            case .space:
                out += " "
            case .char(let character):
                switch character {
                case "%":
                    throw .structure("a bare % would hide the rest of the line; write \\%")
                case "$":
                    throw .structure("a dollar sign inside a formula; write \\$")
                case "#":
                    guard parameters > 0, i + 1 < tokens.count, case .char(let digit) = tokens[i + 1],
                          let number = digit.wholeNumberValue, (1...parameters).contains(number) else {
                        throw .structure("a bare # in a formula; write \\#")
                    }
                    out += "#" + String(digit)
                    i += 1
                case "&":
                    guard !environments.isEmpty else { throw .structure("& outside a matrix or an alignment") }
                    out += "&"
                default:
                    if character.isASCII {
                        out.append(character)
                    } else if inText || pending.text {
                        if let form = TeXTables.textForms[character] {
                            out += form
                        } else if TeXTables.passesInText(character) {
                            out.append(character)
                        } else {
                            throw .character(character)
                        }
                    } else if TeXTables.superscripts[character] != nil || TeXTables.subscripts[character] != nil {
                        // A run of ² or ₃ becomes one script: p²³ is p^{23}.
                        let superscript = TeXTables.superscripts[character] != nil
                        let table = superscript ? TeXTables.superscripts : TeXTables.subscripts
                        var run = ""
                        while i < tokens.count, case .char(let next) = tokens[i], let plain = table[next] {
                            run.append(plain)
                            i += 1
                        }
                        out += (superscript ? "^{" : "_{") + run + "}"
                        continue
                    } else if let form = TeXTables.mathForms[character] {
                        out += form
                    } else {
                        throw .character(character)
                    }
                }
                pending = (false, false)
            }
            i += 1
        }
        // A `^` written before a Unicode superscript would come out as `^^{…}`.
        guard !out.contains("^^") else { throw .structure(Self.doubleCaret) }
        return out
    }

    static let doubleCaret = "two ^ in a row are TeX's notation for an arbitrary character, so they are refused; write the superscript once"
}
