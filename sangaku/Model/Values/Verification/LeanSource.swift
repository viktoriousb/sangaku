import Foundation

/// A statement's Lean code in two parts. The statement part holds any definitions the statement needs and then
/// `theorem main …` up to and including its type; the proof part begins with `:=`. A person's fidelity review binds to
/// the statement part, so everything that can change what is proved is in what they read (invariant 12).
nonisolated struct LeanSource: Hashable, Sendable {
    let statementPart: String
    let proofPart: String

    /// Line endings normalized and blank lines around each part dropped, so the same code always has the same text.
    init(statementPart: String, proofPart: String) {
        self.statementPart = Self.normalize(statementPart)
        self.proofPart = Self.normalize(proofPart)
    }

    /// What is checked and stored: the statement part, a line break, then the proof.
    var text: String { statementPart + "\n" + proofPart }

    static func normalize(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = unified.components(separatedBy: "\n").map { line in
            String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// Reading Lean code without running it: comments blanked out (line and column positions kept), names, and the target
/// declaration. Checked code holds no string, character or quoted-name literal (`LeanGate` refuses them), so once the
/// comments are blanked everything left is code.
nonisolated enum LeanLexicon {
    /// One name or word in blanked code: a run of identifier characters (`Nat.succ_le`, `h'`, `run_tac`, `.foo`).
    nonisolated struct Token: Hashable, Sendable {
        let text: String
        /// Character offsets in the code.
        let start: Int
        let end: Int

        /// The dot-separated parts: `Lean.Elab.Command` gives `Lean`, `Elab`, `Command`.
        var components: [Substring] { text.split(separator: ".") }
    }

    /// The text with every comment replaced by spaces, line breaks kept. `balanced` is false when a block comment is
    /// left open.
    static func blank(_ text: String) -> (code: String, balanced: Bool) {
        var output: [Character] = []
        let characters = Array(text)
        var index = 0
        var depth = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if depth > 0 {
                if character == "/" && next == "-" {
                    depth += 1
                    output.append(contentsOf: "  ")
                    index += 2
                    continue
                }
                if character == "-" && next == "/" {
                    depth -= 1
                    output.append(contentsOf: "  ")
                    index += 2
                    continue
                }
                output.append(character == "\n" ? "\n" : " ")
            } else if character == "/" && next == "-" {
                depth = 1
                output.append(contentsOf: "  ")
                index += 2
                continue
            } else if character == "-" && next == "-" {
                while index < characters.count, characters[index] != "\n" {
                    output.append(" ")
                    index += 1
                }
                continue
            } else {
                output.append(character)
            }
            index += 1
        }
        return (String(output), depth == 0)
    }

    /// Characters that continue a Lean name.
    static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "'" || character == "!"
            || character == "?" || character == "."
    }

    /// Every name or word in blanked code, in order.
    static func tokens(in code: String) -> [Token] {
        let characters = Array(code)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            guard isIdentifier(characters[index]) else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, isIdentifier(characters[index]) { index += 1 }
            tokens.append(Token(text: String(characters[start..<index]), start: start, end: index))
        }
        return tokens
    }

    /// Where a whole-word token occurs in blanked code, as 1-based lines and 0-based columns (Lean's own convention).
    static func occurrences(of word: String, in code: String) -> [LeanLocation] {
        var found: [LeanLocation] = []
        for (lineIndex, line) in code.components(separatedBy: "\n").enumerated() {
            let characters = Array(line)
            let target = Array(word)
            var column = 0
            while column + target.count <= characters.count {
                if Array(characters[column..<(column + target.count)]) == target,
                   column == 0 || !isIdentifier(characters[column - 1]),
                   column + target.count == characters.count || !isIdentifier(characters[column + target.count]) {
                    found.append(LeanLocation(line: lineIndex + 1, column: column))
                    column += target.count
                } else {
                    column += 1
                }
            }
        }
        return found
    }

    /// The `sorry`s and `admit`s in the code, in order.
    static func sorries(in text: String) -> [LeanLocation] {
        let code = blank(text).code
        return (occurrences(of: "sorry", in: code) + occurrences(of: "admit", in: code))
            .sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// The keywords that begin a declaration at the start of a line.
    static let declarationKeywords: Set<String> = [
        "theorem", "lemma", "def", "abbrev", "instance", "structure", "inductive", "class", "example", "opaque",
        "noncomputable", "private", "protected", "partial", "local", "@[", "attribute",
    ]

    /// The first word of each line that starts at column 0, with the offset of the line in the code.
    static func lineStarts(in code: String) -> [(word: String, offset: Int, line: String)] {
        var result: [(String, Int, String)] = []
        var offset = 0
        for line in code.components(separatedBy: "\n") {
            if let first = line.first, !first.isWhitespace {
                let word = line.hasPrefix("@[") ? "@[" : String(line.prefix { isIdentifier($0) && $0 != "." })
                result.append((word, offset, line))
            }
            offset += line.count + 1
        }
        return result
    }

    /// The character offset of the target declaration (`theorem main` or `lemma main` at the start of a line), if it
    /// is the last declaration in the code.
    static func targetOffset(in code: String) -> Int? {
        guard let last = lineStarts(in: code).last(where: { declarationKeywords.contains($0.word) }),
              isTarget(last.line) else { return nil }
        return last.offset
    }

    /// `theorem main` or `lemma main` followed by a binder, a colon or the end of the line.
    static func isTarget(_ line: String) -> Bool {
        for keyword in ["theorem main", "lemma main"] where line.hasPrefix(keyword) {
            let rest = line.dropFirst(keyword.count)
            guard let next = rest.first else { return true }
            return next == " " || next == "(" || next == "{" || next == "[" || next == ":" || next == "⦃"
        }
        return false
    }

    /// The offset of the first `:=` at bracket depth 0 at or after `start`.
    static func firstAssignAtDepthZero(in code: String, from start: Int) -> Int? {
        let characters = Array(code)
        var depth = 0
        var index = start
        while index < characters.count {
            switch characters[index] {
            case "(", "[", "{", "⟨", "⦃": depth += 1
            case ")", "]", "}", "⟩", "⦄": depth = max(0, depth - 1)
            case ":" where depth == 0 && index + 1 < characters.count && characters[index + 1] == "=":
                return index
            default: break
            }
            index += 1
        }
        return nil
    }
}

/// Refuses Lean code before anything runs. Checked code is mathematics: definitions, the target theorem and its proof,
/// with Mathlib's tactics. It may not program Lean itself (no meta-programs, elaborators, macros, notation or quoted
/// syntax), reach Lean's own namespaces, add axioms, leave its namespace, or change how other statements' code reads
/// (only `local` instances, attributes from a short list, a few resource options). What a check means rests on the
/// app's separate kernel check (`AxiomCheck.lean`); the gate keeps the code to what that check and a person's fidelity
/// review can account for (invariant 12).
nonisolated enum LeanGate {
    nonisolated enum Refusal: Error, Hashable, Sendable {
        case empty
        case tooLong
        case hiddenCharacter(String)
        case unbalanced
        /// A string, character or quoted-name literal: `"`, `'`, a backtick or `«`.
        case literal(String)
        case noTarget
        case assignInStatement
        case proofMustStartWithAssign
        case banned(String)
        case attribute(String)
        case option(String)
        case globalInstance

        var message: String {
            switch self {
            case .empty: "The statement part and the proof are both needed."
            case .tooLong: "The Lean code is longer than 200 KB."
            case .hiddenCharacter(let name): "The code holds an invisible or control character (\(name)), so what is shown would differ from what runs."
            case .unbalanced: "A block comment is left open."
            case .literal(let mark): "Strings, characters and quoted names (\(mark)) are not allowed in checked code."
            case .noTarget: "The statement part must end with `theorem main …` (or `lemma main`) at the start of a line, after any definitions."
            case .assignInStatement: "The statement part must stop before `:=`; the proof goes in the proof part."
            case .proofMustStartWithAssign: "The proof must begin with `:=`."
            case .banned(let word): "`\(word)` is not allowed in checked code."
            case .attribute(let name): "The attribute `\(name)` is not allowed in checked code. Allowed: \(LeanGate.allowedAttributes.sorted().joined(separator: ", ")), and `local instance`."
            case .option(let name): "`set_option \(name)` is not allowed in checked code. Allowed: \(LeanGate.allowedOptions.sorted().joined(separator: ", "))."
            case .globalInstance: "An instance must be `local instance`, so that it cannot change how other statements' code reads."
            }
        }
    }

    static let maximumLength = CodeText.maximumLength

    /// Words and name parts that would let code run meta-programs, add axioms, define syntax or notation, leave its
    /// namespace or change how other code reads.
    static let bannedWords: Set<String> = [
        "import", "namespace", "section", "end", "export", "mutual", "axiom", "unsafe", "partial", "implemented_by",
        "extern", "run_cmd", "run_elab", "run_meta", "run_tac", "by_elab", "initialize", "builtin_initialize", "macro",
        "macro_rules", "syntax", "elab", "elab_rules", "declare_syntax_cat", "notation", "notation3", "infix", "infixl",
        "infixr", "prefix", "postfix", "simproc", "dsimproc", "simproc_decl", "dsimproc_decl", "deriving", "_root_",
        "register_simp_attr", "register_option", "add_decl_doc", "library_note",
    ]

    /// Namespaces of Lean's own machinery (elaboration, meta-programming, input and output), refused as any part of a
    /// name, `open` included.
    static let bannedNamespaces: Set<String> = [
        "Lean", "Elab", "Meta", "IO", "EIO", "BaseIO", "System", "Tactic", "Qq", "Aesop", "Parser", "PrettyPrinter",
        "Delaborator", "Widget", "ProofWidgets",
    ]

    /// Attributes that only tag a statement's own lemmas for Mathlib's tactics or set its own definitions' reducibility.
    static let allowedAttributes: Set<String> = [
        "simp", "ext", "simps", "norm_cast", "push_cast", "gcongr", "mono", "fun_prop", "continuity", "measurability",
        "symm", "refl", "trans", "reducible", "irreducible", "semireducible", "nolint", "deprecated", "elab_as_elim",
        "match_pattern",
    ]

    /// Options that only give a proof more time or room.
    static let allowedOptions: Set<String> = [
        "maxHeartbeats", "maxRecDepth", "synthInstance.maxHeartbeats", "synthInstance.maxSize",
    ]

    static func refusal(for source: LeanSource) -> Refusal? {
        guard !source.statementPart.isEmpty, !source.proofPart.isEmpty else { return .empty }
        guard source.text.utf8.count <= maximumLength else { return .tooLong }
        if let scalar = CodeText.hiddenScalar(in: source.text) { return .hiddenCharacter(CodeText.name(scalar)) }
        let (code, balanced) = LeanLexicon.blank(source.text)
        guard balanced else { return .unbalanced }
        if let mark = literal(in: code) { return .literal(mark) }
        if let command = firstCommand(in: code) { return .banned(command) }
        if let refusal = refusal(tokens: LeanLexicon.tokens(in: code), in: Array(code)) { return refusal }
        if let refusal = attributeRefusal(in: code) { return refusal }
        let statement = LeanLexicon.blank(source.statementPart).code
        guard let target = LeanLexicon.targetOffset(in: statement) else { return .noTarget }
        if LeanLexicon.firstAssignAtDepthZero(in: statement, from: target) != nil { return .assignInStatement }
        let proof = LeanLexicon.blank(source.proofPart).code.drop { $0.isWhitespace }
        guard proof.hasPrefix(":=") else { return .proofMustStartWithAssign }
        return nil
    }

    /// The other statements a part's code names, as the twelve hex digits of their namespaces (`S1a2b3c4d5e6f` gives
    /// `1a2b3c4d5e6f`). The service allows a proof to name only statements its statement uses, and a statement part to
    /// name none, so what a statement says never depends on another statement's code.
    static func references(in text: String) -> Set<String> {
        var found: Set<String> = []
        for token in LeanLexicon.tokens(in: LeanLexicon.blank(text).code) {
            for part in token.components where isStatementNamespace(part) { found.insert(String(part.dropFirst())) }
        }
        return found
    }

    /// `S` and twelve lower-case hex digits: `LeanNaming.namespace`'s last part.
    static func isStatementNamespace(_ part: Substring) -> Bool {
        part.count == 13 && part.first == "S" && part.dropFirst().allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// A string (`"`), a quoted name or syntax (a backtick), a guillemet name (`«`) or a character literal (`'a'`,
    /// `'\n'`). `''` (Mathlib's image) and a prime ending a name (`h'`, `⁻¹'`) are not literals.
    private static func literal(in code: String) -> String? {
        let characters = Array(code)
        for (index, character) in characters.enumerated() {
            switch character {
            case "\"": return "\""
            case "`": return "`"
            case "«", "»": return "«"
            case "'":
                guard index == 0 || !LeanLexicon.isIdentifier(characters[index - 1]), index + 1 < characters.count
                else { continue }
                let next = characters[index + 1]
                if next == "\\" { return "'" }
                if next != "'", index + 2 < characters.count, characters[index + 2] == "'" { return "'" }
            default: continue
            }
        }
        return nil
    }

    /// Banned words and namespaces, instances that are not local, `scoped` outside `open scoped`, and options outside
    /// the list.
    private static func refusal(tokens: [LeanLexicon.Token], in characters: [Character]) -> Refusal? {
        func adjacent(_ first: LeanLexicon.Token, _ second: LeanLexicon.Token) -> Bool {
            characters[first.end..<second.start].allSatisfy(\.isWhitespace)
        }
        for (index, token) in tokens.enumerated() {
            for part in token.components {
                if bannedWords.contains(String(part)) || bannedNamespaces.contains(String(part)) { return .banned(String(part)) }
            }
            let previous = index > 0 ? tokens[index - 1] : nil
            switch token.text {
            case "instance":
                guard let previous, previous.text == "local", adjacent(previous, token) else { return .globalInstance }
            case "scoped":
                guard let previous, previous.text == "open", adjacent(previous, token) else { return .banned("scoped") }
            case "set_option":
                guard index + 1 < tokens.count, adjacent(token, tokens[index + 1]) else { return .option("") }
                let name = tokens[index + 1].text
                guard allowedOptions.contains(name) else { return .option(name) }
            default: break
            }
        }
        return nil
    }

    /// Every attribute in `@[…]` and `attribute […]` must be on the list; `instance` only as `local instance`.
    private static func attributeRefusal(in code: String) -> Refusal? {
        let characters = Array(code)
        var index = 0
        while index < characters.count {
            let opens: Bool
            if characters[index] == "@", index + 1 < characters.count, characters[index + 1] == "[" {
                opens = true
                index += 1
            } else if characters[index] == "[", attributeKeywordEnds(at: index, in: characters) {
                opens = true
            } else {
                opens = false
            }
            guard opens else {
                index += 1
                continue
            }
            // From `[` to its matching `]`.
            var depth = 0
            var end = index
            while end < characters.count {
                if characters[end] == "[" { depth += 1 }
                if characters[end] == "]" {
                    depth -= 1
                    if depth == 0 { break }
                }
                end += 1
            }
            guard end < characters.count else { return .unbalanced }
            for item in items(String(characters[(index + 1)..<end])) {
                if let refusal = attributeRefusal(item: item) { return refusal }
            }
            index = end + 1
        }
        return nil
    }

    /// Whether the `[` at `index` follows the word `attribute`.
    private static func attributeKeywordEnds(at index: Int, in characters: [Character]) -> Bool {
        var end = index
        while end > 0, characters[end - 1].isWhitespace { end -= 1 }
        let keyword = Array("attribute")
        guard end >= keyword.count, Array(characters[(end - keyword.count)..<end]) == keyword else { return false }
        return end == keyword.count || !LeanLexicon.isIdentifier(characters[end - keyword.count - 1])
    }

    /// The comma-separated items of an attribute list, at bracket depth 0.
    private static func items(_ list: String) -> [String] {
        var items: [String] = []
        var current = ""
        var depth = 0
        for character in list {
            switch character {
            case "(", "[", "{", "⟨": depth += 1
            case ")", "]", "}", "⟩": depth -= 1
            case "," where depth == 0:
                items.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        items.append(current)
        return items
    }

    private static func attributeRefusal(item: String) -> Refusal? {
        var words = item.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first?.hasPrefix("-") == true {
            let rest = String(words[0].dropFirst())
            words = rest.isEmpty ? Array(words.dropFirst()) : [rest] + words.dropFirst()
        }
        var isLocal = false
        if words.first == "local" {
            isLocal = true
            words.removeFirst()
        }
        guard let first = words.first else { return .attribute("") }
        let name = String(first.prefix { LeanLexicon.isIdentifier($0) })
        if name == "instance" { return isLocal ? nil : .globalInstance }
        return allowedAttributes.contains(name) ? nil : .attribute(name)
    }

    /// A `#` command (`#eval`, `#exit`, `#print`): `#` followed by a letter.
    private static func firstCommand(in code: String) -> String? {
        let characters = Array(code)
        for index in characters.indices where characters[index] == "#" {
            guard index + 1 < characters.count, characters[index + 1].isLetter else { continue }
            return "#" + String(characters[(index + 1)...].prefix { $0.isLetter || $0 == "_" })
        }
        return nil
    }
}
