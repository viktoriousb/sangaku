import Foundation

/// Turns a snapshot into a document, passing every text through the gate. Pure; refusals are collected and thrown
/// together, so a person sees every text to fix at once and nothing is written while any remains.
nonisolated enum ExportComposer {
    static func compose(_ snapshot: ExportSnapshot, scope: ExportScope,
                        verdicts: FormulaVerdicts) throws(ExportError) -> ExportDocument {
        var gate = Gate(macros: snapshot.macros, verdicts: verdicts)
        let statements = ordered(snapshot.statements(in: scope))
        let inScope = Set(statements.map(\.id))
        let attempts = snapshot.attempts(in: scope)
        let ordinal = snapshot.attemptNumbers(in: scope)
        let several = attempts.count > 1
        let byID = Dictionary(statements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let items = statements.map { statement in
            item(statement, snapshot: snapshot, inScope: inScope, byID: byID,
                 attempt: { several ? ordinal[$0] : nil }, gate: &gate)
        }

        let aiUse = AIUseStatement.of(snapshot, scope: scope).paragraphs.map { paragraph in
            TeXFragment.joined(paragraph.map { gate.pieces($0.pieces, at: .aiUse) }, separator: " ")
        }

        var references: [ExportDocument.Reference] = []
        var seen = Set<UUID>()
        for attempt in attempts {
            for step in attempt.steps {
                let place = TeXLocation.citation(step.index, attempt: several ? ordinal[attempt.id] : nil)
                for citation in step.citations where seen.insert(citation.id).inserted {
                    if let reference = reference(citation, at: place, gate: &gate) { references.append(reference) }
                }
            }
        }

        let notation = snapshot.notation.map { row in
            ExportDocument.NotationLine(symbol: gate.prose("$" + row.symbol + "$", at: .notation(row.symbol)),
                                        meaning: gate.prose(row.meaning, at: .notation(row.symbol)))
        }
        let macros = snapshot.macros.definitions.values.sorted { $0.name < $1.name }.map { definition in
            gate.run(at: .notation(definition.name)) { () throws(TeXRefusal) in
                try TeXGate.macro(definition, macros: snapshot.macros)
            }
        }
        let argument = (snapshot.theorem?.sources ?? []).compactMap(snapshot.step).map { step in
            gate.line(step.establishes, at: .establishes(step.index, attempt: nil))
        }
        // Unbraced: amsart upper-cases a title but not its mathematics, which braces would hide from it.
        let title = gate.line(snapshot.title, at: .title)

        guard gate.refusals.isEmpty else { throw .refused(gate.refusals) }
        return ExportDocument(scope: scope, title: title, items: items, aiUse: aiUse, references: references,
                              notation: notation, macros: macros, argument: argument)
    }

    /// Dependencies before what uses them, otherwise in graph order. A cycle (which the graph refuses) cannot hang it.
    static func ordered(_ statements: [ExportStatement]) -> [ExportStatement] {
        let byID = Dictionary(statements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<UUID>()
        var visiting = Set<UUID>()
        var out: [ExportStatement] = []
        func visit(_ statement: ExportStatement) {
            guard !placed.contains(statement.id), visiting.insert(statement.id).inserted else { return }
            for dependency in statement.uses { if let next = byID[dependency] { visit(next) } }
            placed.insert(statement.id)
            out.append(statement)
        }
        // The theorem last among what it does not precede, so it closes the results.
        for statement in statements where !statement.isPinned { visit(statement) }
        for statement in statements where statement.isPinned { visit(statement) }
        return out
    }

    private static func item(_ statement: ExportStatement, snapshot: ExportSnapshot, inScope: Set<UUID>,
                             byID: [UUID: ExportStatement], attempt: (UUID) -> Int?,
                             gate: inout Gate) -> ExportDocument.Item {
        let (group, environment) = ExportDocument.placement(of: statement)
        let refuted = group == .refuted
        let imported = group == .imported

        let name = gate.plain(statement.label, at: .statement(statement.label))
        var title = "{" + name + "}"
        var source: TeXFragment?
        if imported, let text = statement.importedSource {
            let gated = gate.plain(text, at: .importedSource(statement.label))
            title = "{" + name + "; \\imported{" + gated + "}}"
            source = gated
        }

        let status = ExportWording.status(statement).map { gate.pieces($0, at: .status(statement.label)) }
        let dependencies = statement.uses.filter(inScope.contains).compactMap { byID[$0] }
        let uses: TeXFragment? = dependencies.isEmpty ? nil
            : "Uses " + TeXFragment.joined(dependencies.map { reference(to: $0) }, separator: ", ") + "."

        var proof: [ExportDocument.ProofPart] = []
        if group == .lemmas || group == .main {
            var parts: [(attempt: UUID, steps: [ExportStep])] = []
            for ref in statement.sources {
                guard let step = snapshot.step(ref) else { continue }
                if let last = parts.indices.last, parts[last].attempt == ref.attemptID {
                    parts[last].steps.append(step)
                } else {
                    parts.append((ref.attemptID, [step]))
                }
            }
            proof = parts.map { part in
                let number = attempt(part.attempt)
                return ExportDocument.ProofPart(
                    source: gate.plain(ExportWording.proofSource(part.steps.map(\.index), attempt: number),
                                       at: .statement(statement.label)),
                    steps: part.steps.map { step in
                        ExportDocument.Step(
                            number: step.index,
                            establishes: gate.line(step.establishes, at: .establishes(step.index, attempt: number)),
                            text: gate.prose(step.text, at: .step(step.index, attempt: number)),
                            provenance: gate.plain(ExportWording.provenance(step), at: .step(step.index, attempt: number)),
                            citations: step.citations.map { citation in
                                let place = TeXLocation.citation(step.index, attempt: number)
                                let check = gate.plain("(" + ExportWording.citationCheck(citation) + ")", at: place)
                                let cited: TeXFragment = Self.citable(citation)
                                    ? "~\\cite{" + TeXGate.citationKey(citation.id) + "}" : .empty
                                return gate.cited(citation.text, at: place) + " " + check + cited
                            })
                    })
            }
        }

        let refutation: TeXFragment? = refuted
            ? "A person accepted a refutation" + (statement.refutationNote.map { note in
                ": " + gate.prose(note, at: .refutation(statement.label))
            } ?? ".")
            : nil

        return ExportDocument.Item(
            id: statement.id, group: group, environment: environment, label: TeXGate.label(statement.kind, statement.id),
            name: name, title: title,
            statement: gate.prose(statement.text, at: .statement(statement.label)),
            status: status, uses: uses, proof: proof, refutation: refutation,
            statusWords: gate.plain(ExportWording.statusWords(statement.derived,
                                                              assumed: statement.derived.assumes.compactMap { byID[$0]?.label }),
                                    at: .status(statement.label)),
            importedSource: source)
    }

    /// "Lemma~\ref{lem:s…}", by the environment the statement is written in.
    private static func reference(to statement: ExportStatement) -> TeXFragment {
        ExportDocument.placement(of: statement).environment.word + "~\\ref{" + TeXGate.label(statement.kind, statement.id) + "}"
    }

    /// A found citation with the index's authors and title becomes a reference; any other is printed as written.
    /// BibTeX counts braces even when escaped, so a field with a brace or a backslash stays printed text.
    static func citable(_ citation: ExportCitation) -> Bool {
        let fields = [citation.matchedTitle ?? ""] + citation.matchedAuthors
        return citation.status == .found && !(citation.matchedTitle ?? "").isEmpty && !citation.matchedAuthors.isEmpty
            && fields.allSatisfy { !$0.contains(where: { "{}\\".contains($0) }) }
    }

    private static func reference(_ citation: ExportCitation, at place: TeXLocation,
                                  gate: inout Gate) -> ExportDocument.Reference? {
        guard citable(citation), let title = citation.matchedTitle else { return nil }
        return ExportDocument.Reference(
            key: TeXGate.citationKey(citation.id),
            authors: citation.matchedAuthors.map { gate.plain($0, at: place) },
            title: gate.cited(title, at: place), year: citation.matchedYear,
            link: citation.link.flatMap(TeXGate.url),
            index: gate.plain(citation.indexName ?? "an index", at: place))
    }

    /// Collects refusals instead of stopping at the first.
    struct Gate {
        let macros: MacroSet
        let verdicts: FormulaVerdicts
        var refusals: [ExportRefusal] = []

        mutating func run(at location: TeXLocation, _ make: () throws(TeXRefusal) -> TeXFragment) -> TeXFragment {
            do {
                return try make()
            } catch {
                refusals.append(ExportRefusal(location: location, refusal: error))
                return .empty
            }
        }

        mutating func plain(_ text: String, at location: TeXLocation) -> TeXFragment {
            run(at: location) { () throws(TeXRefusal) in try TeXGate.plain(text) }
        }

        mutating func prose(_ text: String, at location: TeXLocation) -> TeXFragment {
            let (macros, verdicts) = (self.macros, self.verdicts)
            return run(at: location) { () throws(TeXRefusal) in try TeXGate.prose(text, macros: macros, verdicts: verdicts) }
        }

        /// One line of prose with mathematics: the title, what a step establishes.
        mutating func line(_ text: String, at location: TeXLocation) -> TeXFragment {
            prose(TeXGate.line(text), at: location)
        }

        /// A line no one here can edit (a citation as a model wrote it, a title an index returned): its mathematics
        /// typeset when the gate takes it, else the line printed as written.
        mutating func cited(_ text: String, at location: TeXLocation) -> TeXFragment {
            if let typeset = try? TeXGate.prose(TeXGate.line(text), macros: macros, verdicts: verdicts) { return typeset }
            return plain(text, at: location)
        }

        mutating func pieces(_ pieces: [ExportPiece], at location: TeXLocation) -> TeXFragment {
            TeXFragment.joined(pieces.map { piece in
                switch piece {
                case .text(let text): plain(text, at: location)
                case .prose(let text): prose(text, at: location)
                }
            })
        }
    }
}
