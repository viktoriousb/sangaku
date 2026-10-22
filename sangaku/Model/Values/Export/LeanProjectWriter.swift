import Foundation

/// A file an export writes, by its path inside the export's folder.
nonisolated struct ExportFile: Hashable, Sendable {
    var path: String
    var contents: String
}

/// Why the Lean project cannot be exported.
nonisolated enum LeanProjectError: Error, Hashable, Sendable {
    case nothingChecked
    case codeRefused(label: String, LeanGate.Refusal)
    case namesOtherStatement(label: String, named: String)
    case hidden(label: String)

    var message: String {
        switch self {
        case .nothingChecked: "No statement has Lean code that was checked, so there is no Lean project to export."
        case .codeRefused(let label, let refusal): "The checked Lean code of \(label) is refused: \(refusal.message)"
        case .namesOtherStatement(let label, let named):
            "The checked Lean code of \(label) names \(named), which it may not, so the module would not be the one checked. Check \(label) again."
        case .hidden(let label): "\(label) holds an invisible or control character, so it cannot be written to the README."
        }
    }
}

/// The Lean project export: a Lake package requiring Mathlib at the pinned release, with the problem's module exactly
/// as the app assembles it from every statement's checked code (never a draft), and a README that says where each
/// check stands. Nothing runs; a person builds it with Lake.
nonisolated enum LeanProjectWriter {
    static func files(_ snapshot: ExportSnapshot) throws(LeanProjectError) -> [ExportFile] {
        let checked = snapshot.statements.filter { $0.lean?.source != nil }
        guard !checked.isEmpty else { throw .nothingChecked }
        let labels = Dictionary(snapshot.statements.map { (LeanNaming.short($0.id), $0.label) },
                                uniquingKeysWith: { first, _ in first })
        let uses = Dictionary(snapshot.statements.map { ($0.id, $0.uses) }, uniquingKeysWith: { first, _ in first })
        var sources: [UUID: LeanSource] = [:]
        for statement in checked {
            guard let source = statement.lean?.source else { continue }
            if let refusal = LeanGate.refusal(for: source) { throw .codeRefused(label: statement.label, refusal) }
            if let violation = LeanGate.referenceViolation(in: source, own: statement.id,
                                                          uses: closure(of: statement.id, uses: uses)) {
                throw .namesOtherStatement(label: statement.label,
                                           named: labels[violation.named] ?? "a statement no longer in the problem")
            }
            sources[statement.id] = source
        }
        let order = LeanModuleOrder.order(checked.map {
            LeanModuleOrder.Node(id: $0.id, createdAt: $0.createdAt, uses: $0.uses)
        })
        let module = LeanModulePlan(order.compactMap { id in sources[id].map { (id, $0) } })
        let library = libraryName(snapshot.problemID)
        return [
            ExportFile(path: "lean-toolchain", contents: LeanPin.toolchain + "\n"),
            ExportFile(path: "lakefile.toml", contents: lakefile(snapshot.problemID)),
            ExportFile(path: library + ".lean", contents: module.text),
            ExportFile(path: ".gitignore", contents: ".lake/\n"),
            ExportFile(path: "README.md", contents: try readme(snapshot, module: module, order: order)),
        ]
    }

    /// `P1a2b3c4d5e6f`: the library and its one module, from the problem's stable ID.
    static func libraryName(_ problem: UUID) -> String { "P" + LeanNaming.short(problem) }

    static func lakefile(_ problem: UUID) -> String {
        """
        name = "p\(LeanNaming.short(problem))"
        defaultTargets = ["\(libraryName(problem))"]

        [[require]]
        name = "mathlib"
        git = "https://github.com/leanprover-community/mathlib4.git"
        rev = "\(LeanPin.mathlibRev)"

        [[lean_lib]]
        name = "\(libraryName(problem))"

        """
    }

    /// Everything `id` uses, directly or through others.
    private static func closure(of id: UUID, uses: [UUID: [UUID]]) -> [UUID] {
        var seen: Set<UUID> = [id]
        var stack = uses[id] ?? []
        var found: [UUID] = []
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            found.append(next)
            stack += uses[next] ?? []
        }
        return found
    }

    private static func readme(_ snapshot: ExportSnapshot, module: LeanModulePlan,
                               order: [UUID]) throws(LeanProjectError) -> String {
        let byID = Dictionary(snapshot.statements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let file = libraryName(snapshot.problemID) + ".lean"
        var lines = [
            "# Lean project: " + (try markdown(snapshot.title, label: "The title")),
            "",
            "Generated from the problem's record. `\(file)` holds each statement's checked Lean code in its own namespace, in the order the app checks it; drafts are never included. It requires Mathlib \(LeanPin.mathlibRev) on \(LeanPin.toolchain). Build it with `lake exe cache get` and then `lake build`.",
            "",
            "Only \u{201C}verified in Lean\u{201D} means that " + ExportWording.verifiedMeaning + ". The axioms are read by the app's own kernel check; the standard ones are `propext`, `Classical.choice` and `Quot.sound`.",
            "",
            "| Statement | Namespace | Lean | Code by | Checked |",
            "|---|---|---|---|---|",
        ]
        for id in order {
            guard let statement = byID[id], let lean = statement.lean else { continue }
            let day = lean.checkedAt.map(ExportWording.day) ?? "not recorded"
            let sameModule = lean.moduleDigest == module.digest.hex
                ? "in this module" : "in an earlier module; its own code here is the code checked"
            lines.append("| " + (try markdown(statement.label, label: statement.label)) + " | `"
                         + LeanNaming.namespace(for: id) + "` | " + ExportWording.lean(lean.standing) + " | "
                         + ExportWording.actor(lean.codeAuthor) + " | " + day + ", " + sameModule + " |")
        }
        let statement = AIUseStatement.of(snapshot, scope: .everyStatement)
        lines += ["", "## " + AIUseStatement.heading, ""]
        for paragraph in statement.paragraphs {
            var text = ""
            for sentence in paragraph {
                for piece in sentence.pieces {
                    switch piece {
                    case .text(let words): text += try markdown(words, label: "The AI-use statement")
                    case .prose(let prose): text += try markdownProse(prose)
                    }
                }
                text += " "
            }
            lines += [text.trimmingCharacters(in: .whitespaces), ""]
        }
        return lines.joined(separator: "\n")
    }

    /// One line of text, shown as typed: Markdown's special characters are escaped, so nothing becomes a link,
    /// an image, a heading or HTML.
    static func markdown(_ text: String, label: String) throws(LeanProjectError) -> String {
        if CodeText.hiddenScalar(in: text) != nil { throw .hidden(label: label) }
        var out = ""
        for character in TeXGate.oneLine(text) {
            if "\\`*_{}[]()<>#+-.!|~$&".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Prose: text escaped, mathematics kept between dollar signs for renderers that typeset it.
    private static func markdownProse(_ prose: String) throws(LeanProjectError) -> String {
        var out = ""
        for segment in ProseSegmenter.segments(prose) {
            switch segment {
            case .text(let text): out += try markdown(text, label: "The AI-use statement")
            case .math(let latex, _):
                let line = latex.split(whereSeparator: \.isNewline).joined(separator: " ")
                out += line.contains("$") || line.contains("`") ? "`" + line.replacingOccurrences(of: "`", with: "'") + "`" : "$" + line + "$"
            case .unterminated(let text): out += try markdown(text, label: "The AI-use statement")
            }
        }
        return out
    }
}
