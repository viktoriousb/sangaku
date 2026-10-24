import Foundation
import Testing
@testable import sangaku

@Suite("Export: the document and the LaTeX file")
struct ExportComposerTests {
    private let fixture = PreviewFixtures.make()

    private var snapshot: ExportSnapshot {
        ExportSnapshot.read(problem: fixture.problem, people: fixture.state.problems.personIDs())
    }

    private func document(_ scope: ExportScope = .theoremAndUses) throws -> ExportDocument {
        let snapshot = snapshot
        return try ExportComposer.compose(snapshot, scope: scope,
                                          verdicts: FormulaVerdicts.read(snapshot, renderer: MathRenderer.standard()))
    }

    private func refusals(_ scope: ExportScope = .theoremAndUses) -> [ExportRefusal] {
        do {
            _ = try document(scope)
            return []
        } catch let error as ExportError {
            guard case .refused(let refusals) = error else { return [] }
            return refusals
        } catch {
            return []
        }
    }

    @Test("The theorem comes after what it uses; labels come from kind and stable ID")
    func order() throws {
        let made = try document()
        #expect(made.items.map(\.name.source) == ["Lem 1", "Lem 2", "Lem 3", "Lem 4", "Thm 1"])
        #expect(made.items.map(\.group) == [.lemmas, .lemmas, .lemmas, .lemmas, .main])
        for item in made.items {
            #expect(item.label.source.wholeMatch(of: /(thm|lem|clm|conj):s[0-9a-f]{12}/) != nil, "\(item.label.source)")
        }
        #expect(try document().items.map(\.label) == made.items.map(\.label), "the same on every export")
        #expect(made.argument.map(\.source) == ["Sylow counts", "q \\textgreater{} p", "n\\_q = p\\textasciicircum{}2",
                                                 "q | p + 1", "Resolve q | p + 1", "Order 12 case"])
    }

    @Test("What a step establishes is typeset like its text, never printed with its dollars; a citation too, else printed as written")
    func oneLineMath() throws {
        func compose(_ establishes: String, citation: String) throws -> ExportDocument {
            var snapshot = snapshot
            let attempt = try #require(snapshot.attempts.firstIndex { $0.id == fixture.attemptA.stableID })
            snapshot.attempts[attempt].steps[0].establishes = establishes
            snapshot.attempts[attempt].steps[0].citations[0].text = citation
            return try ExportComposer.compose(snapshot, scope: .theoremAndUses,
                                              verdicts: FormulaVerdicts.read(snapshot, renderer: MathRenderer.standard()))
        }
        let made = try compose("  $n_p = 1$ or\n $n_p = q$ ", citation: "On $p$-groups, Section 4.5")
        let step = try #require(made.theorem?.proof.first?.steps.first)
        #expect(step.establishes.source == "$n_p = 1$ or $n_p = q$")
        #expect(made.argument.first == step.establishes, "the preface's argument too")
        #expect(step.citations.first?.source.hasPrefix("On $p$-groups, Section 4.5 (") == true, "\(step.citations.first?.source ?? "")")

        // A citation no one here can edit, whose formula the app cannot set: printed as written, not refused.
        let printed = try compose("$n_p = 1$", citation: #"On $\notacommand$-groups"#)
        #expect(printed.theorem?.proof.first?.steps.first?.citations.first?.source
                    .hasPrefix(#"On \$\textbackslash{}notacommand\$-groups"#) == true)

        // What a step establishes can be revised, so a formula the app cannot set refuses the export, naming the step.
        do {
            _ = try compose(#"$\notacommand$"#, citation: "x")
            Issue.record("expected a refusal")
        } catch let error as ExportError {
            guard case .refused(let refusals) = error else { throw error }
            #expect(refusals.map(\.location).contains(.establishes(1, attempt: nil)))
        }
    }

    @Test("Invariant 7: each step says who wrote and who checked it, from its history; roles only")
    func provenance() throws {
        let theorem = try #require(try document().theorem)
        let steps = theorem.proof.flatMap(\.steps)
        #expect(steps.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(steps[2].provenance.source == "Written by a language model; revised by a person; checked by a person on its current text; revised after the referee model was asked.")
        #expect(steps[4].provenance.source == "Written by a language model; revised by a language model; an objection from a person is open, so it does not count as checked; revised after the referee model was asked; marked delicate by its writer.")
        #expect(steps[5].provenance.source == "Written by a language model; not checked by a person; covered by the referee model's verdict.")
        #expect(theorem.proof.map(\.source.source) == ["Steps 1–6 of the attempt."])
        #expect(theorem.status.map(\.source).first == "Status: sketched.")
        #expect(theorem.status.map(\.source).contains("4 of 6 steps checked by a person (1 with an open objection)."))
    }

    @Test("Invariant 6: a found citation without the index's authors is printed, never linked or cited; others say their check")
    func citations() throws {
        let made = try document()
        let first = try #require(made.theorem?.proof.first?.steps.first?.citations.first?.source)
        #expect(first == #"Dummit \& Foote, Abstract Algebra, 3rd ed., §4.5 (a matching document was found in zbMATH Open)"#)
        let last = try #require(made.theorem?.proof.first?.steps.last?.citations.first?.source)
        #expect(last.hasSuffix("(not found in arXiv or zbMATH Open)") && !last.contains("cite"))
        #expect(made.references.isEmpty)

        let citation = try #require(fixture.attemptA.sortedSteps[0].citations?.first)
        citation.matchedTitle = "Abstract algebra"
        citation.matchedAuthors = ["Dummit, David S.", "Foote, Richard M."]
        citation.matchedYear = 1991
        citation.resolvedURL = "https://zbmath.org/?q=an:0751.00001"
        let cited = try document()
        #expect(cited.references.count == 1)
        let reference = try #require(cited.references.first)
        #expect(LatexWriter.reference(reference).source.hasPrefix(#"\bibitem{cit"#))
        #expect(LatexWriter.reference(reference).source.hasSuffix(#", \emph{Abstract algebra}, 1991. \url{https://zbmath.org/?q=an:0751.00001}. Matched in zbMATH Open."#))
        #expect(cited.theorem?.proof.first?.steps.first?.citations.first?.source.contains("~\\cite{cit") == true)
    }

    @Test("Every statement: imported, open and refuted statements take their own forms")
    func everyStatement() throws {
        try fixture.state.graph.setImported(fixture.conjecture.stableID, source: "Sylow, Theorem 1", in: fixture.problem)
        let made = try document(.everyStatement)
        let byName = Dictionary(uniqueKeysWithValues: made.items.map { ($0.name.source, $0) })
        let conj = try #require(byName["Conj"])
        #expect(conj.group == .imported && conj.proof.isEmpty)
        #expect(conj.title.source == #"{Conj; \imported{Sylow, Theorem 1}}"#)
        let claim = try #require(byName["Claim"])
        #expect(claim.group == .refuted && claim.proof.isEmpty && claim.environment == .claim)
        #expect(claim.refutation?.source == #"A person accepted a refutation: $n_q = p$ needs $p \equiv 1 \pmod{p}$, impossible since $p < q$."#
                || claim.refutation?.source.hasPrefix("A person accepted a refutation: $n_q = p$") == true)
        let lemma5 = try #require(byName["Lem 5"])
        #expect(lemma5.group == .open && lemma5.environment == .conjecture, "no steps: a conjecture, with its evidence")
        #expect(lemma5.status.map(\.source).contains { $0.hasPrefix("Lean: verified in Lean") })
        #expect(byName["Lem 6"]?.status.map(\.source).contains("Depends on a refuted claim: Claim.") == true)
        #expect(made.items.last?.group == .main || made.items.contains { $0.group == .main })
    }

    @Test("Invariant 16 and the gate: refused texts are all listed, each by its place; nothing is made")
    func refused() {
        fixture.lemmas[1].statementLaTeX = #"Bad $\frac{a$ here."#
        fixture.attemptA.sortedSteps[3].textLaTeX = #"Runs $\input{x}$."#
        fixture.attemptA.sortedSteps[3].latestRevision?.textLaTeX = #"Runs $\input{x}$."#
        let found = refusals()
        #expect(found.map(\.location).contains(.statement("Lem 2")))
        // The app's renderer refuses \input first (strict parsing), so it is a formula shown as its source.
        #expect(found.contains { $0.location == .step(4, attempt: nil) && { if case .unrendered = $0.refusal { true } else { false } }($0) })
        #expect(found.allSatisfy { !$0.message.isEmpty })
        #expect(ExportError.refused(found).message.hasPrefix("Nothing was exported: "))
    }

    @Test("TeX's ^^ notation is refused through the real renderer, wherever it is written")
    func doubleCaret() {
        fixture.lemmas[0].statementLaTeX = #"Spelled $\text{^^5cinput{x}}$."#
        let step = fixture.attemptA.sortedSteps[1]
        step.textLaTeX = #"Spelled $x^^5cinput{foo}$."#
        step.latestRevision?.textLaTeX = step.textLaTeX
        let found = refusals()
        #expect(found.contains { $0.location == .statement("Lem 1") })
        #expect(found.contains { $0.location == .step(2, attempt: nil) })
    }

    @Test("What rests on an imported result says so in the status table and the preface too")
    func assumesEverywhere() throws {
        let lemma2 = fixture.lemmas[1]
        lemma2.uses = (lemma2.uses ?? []) + [fixture.conjecture]
        try fixture.state.graph.setImported(fixture.conjecture.stableID, source: "Sylow, Theorem 1", in: fixture.problem)
        let made = try document(.everyStatement)
        let byName = Dictionary(uniqueKeysWithValues: made.items.map { ($0.name.source, $0) })
        #expect(byName["Lem 2"]?.statusWords.source == "checked by a person; checked internally only; assumes Conj, imported")
        #expect(byName["Thm 1"]?.statusWords.source.hasSuffix("; assumes Conj, imported") == true)
        #expect(LatexWriter.statusTable(made.items).source.contains("assumes Conj, imported"))
        #expect(HashtagWriter.appendix(made).source.contains("assumes Conj, imported"))
        #expect(HashtagWriter.preface(made).source.contains("Its status: sketched; assumes Conj, imported."))
    }

    @Test("Roles only: the LaTeX names no person, slot, model or maker")
    func rolesOnly() throws {
        for scope in [ExportScope.theoremAndUses, .everyStatement] {
            let tex = LatexWriter.write(try document(scope))
            for name in ["MK", "You ", "Model A", "Model B", "Model C", "Claude", "Opus", "Anthropic"] {
                #expect(!tex.contains(name), "\(scope) names \(name)")
            }
        }
    }
}

/// Runs pdfLaTeX in the offline sandbox, as an export does.
struct TeXRun {
    nonisolated static let texBin = "/Library/TeX/texbin"
    nonisolated static let available = FileManager.default.isExecutableFile(atPath: texBin + "/pdflatex")

    var folder: String
    var log: String
    var exitedCleanly: Bool

    /// `passes` runs of `pdflatex -interaction=nonstopmode` on `main.tex`.
    static func run(_ tex: String, passes: Int = 1) async throws -> TeXRun {
        let folder = ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path) + "/sangaku-tex-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data(tex.utf8).write(to: URL(fileURLWithPath: folder + "/main.tex"))
        let environment = ["PATH": texBin + ":/usr/bin:/bin", "HOME": folder, "TMPDIR": folder, "LANG": "en_US.UTF-8",
                           "TEXMFVAR": folder + "/texmf-var", "TEXMFCONFIG": folder + "/texmf-config",
                           "shell_escape": "f", "openout_any": "p", "openin_any": "p"]
        var limits = RunLimits.compute
        limits.seconds = 120
        var clean = true
        for _ in 0..<passes {
            let result = await ProcessExecutor(runningFolder: nil).execute(
                .testing(texBin + "/pdflatex", ["-interaction=nonstopmode", "-no-shell-escape", "main.tex"],
                         runFolder: folder, limits: limits, environment: environment), onOutput: nil)
            clean = result.end == .exited(0)
        }
        let log = (try? String(contentsOfFile: folder + "/main.log", encoding: .utf8))
            ?? (try? String(contentsOfFile: folder + "/main.log", encoding: .isoLatin1)) ?? ""
        return TeXRun(folder: folder, log: log, exitedCleanly: clean)
    }

    /// The input lines TeX reported an error on.
    var errorLines: [Int] {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        var found: [Int] = []
        var inError = false
        for line in lines {
            if line.hasPrefix("! ") { inError = true }
            if inError, line.hasPrefix("l."), let number = Int(line.dropFirst(2).prefix { $0.isNumber }) {
                found.append(number)
                inError = false
            }
        }
        return found
    }

    var errors: [String] { log.split(separator: "\n").filter { $0.hasPrefix("! ") }.map(String.init) }

    func remove() { try? FileManager.default.removeItem(atPath: folder) }
}

@Suite("Export: real pdfLaTeX", .serialized, .enabled(if: TeXRun.available))
struct ExportTeXTests {
    @Test("The fixture's LaTeX export compiles on its own, with no error and no undefined reference")
    func standalone() async throws {
        let fixture = PreviewFixtures.make()
        for scope in [ExportScope.theoremAndUses, .everyStatement] {
            var snapshot = ExportSnapshot.read(problem: fixture.problem, people: fixture.state.problems.personIDs())
            // Mathematics in what a step establishes and in a citation, typeset where each is printed.
            let attempt = try #require(snapshot.attempts.firstIndex { $0.id == fixture.attemptA.stableID })
            snapshot.attempts[attempt].steps[3].establishes = #"$q \mid p + 1$"#
            snapshot.attempts[attempt].steps[0].citations[0].text = "Dummit and Foote, on $p$-groups"
            let document = try ExportComposer.compose(snapshot, scope: scope,
                                                      verdicts: FormulaVerdicts.read(snapshot, renderer: MathRenderer.standard()))
            let tex = LatexWriter.write(document)
            let run = try await TeXRun.run(tex, passes: 2)
            defer { run.remove() }
            #expect(run.exitedCleanly && run.errors.isEmpty, "\(run.errors)")
            #expect(!run.log.contains("undefined references") && !run.log.contains("Reference `"), "\(scope)")
            if let folder = ProcessInfo.processInfo.environment["SANGAKU_PREVIEW_DIR"] {
                let name = scope == .theoremAndUses ? "export-latex" : "export-latex-all"
                try? FileManager.default.removeItem(atPath: folder + "/\(name).pdf")
                try? FileManager.default.copyItem(atPath: run.folder + "/main.pdf", toPath: folder + "/\(name).pdf")
                try Data(tex.utf8).write(to: URL(fileURLWithPath: folder + "/\(name).tex"))
            }
        }
    }

    /// One line per allowed command, environment and character, so an error's line names what failed.
    static func conformanceLines() -> [(String, String)] {
        var lines: [(String, String)] = []
        let special: [String: String] = [
            "left": #"\left( a \middle| b \right)"#, "right": #"\left[ a \right]"#, "middle": #"\left( a \middle| b \right)"#,
            "not": #"\not= x"#, "limits": #"\sum\limits_{i} x"#, "nolimits": #"\sum\nolimits_{i} x"#,
            "hline": #"\begin{array}{c} a \\ \hline b \end{array}"#, "substack": #"\sum_{\substack{a \\ b}} x"#,
            "genfrac": #"\genfrac{(}{)}{0pt}{0}{a}{b}"#, "sqrt": #"\sqrt[3]{x}"#, "operatorname": #"\operatorname*{x}_{y}"#,
        ]
        for name in TeXTables.mathCommands.sorted() where name != "begin" && name != "end" {
            if let usage = special[name] {
                lines.append((name, "$" + usage + "$"))
            } else if ["big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr"].contains(name) {
                lines.append((name, "$\\\(name)( x$"))
            } else {
                let arity = TeXValidator.arity[name] ?? 1
                lines.append((name, "$\\\(name)" + String(repeating: "{x}", count: arity) + "$"))
            }
        }
        for environment in TeXTables.environments.sorted() {
            let body = environment == "gathered" ? #"a \\ b"# : #"a & b \\ c & d"#
            let columns = environment == "array" ? "{cc}" : ""
            lines.append(("env " + environment, #"\[ \begin{"# + environment + "}" + columns + " " + body + #" \end{"# + environment + #"} \]"#))
        }
        for (glyph, form) in TeXTables.mathForms.sorted(by: { $0.key < $1.key }) {
            lines.append(("math " + String(glyph), "$a " + form + "b$"))
        }
        for (glyph, form) in TeXTables.textForms.sorted(by: { $0.key < $1.key }) {
            lines.append(("text " + String(glyph), "a" + form + "b"))
        }
        for value in UInt32(0xC0)...0x17F {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let character = Character(scalar)
            if TeXTables.passesInText(character) { lines.append(("pass " + String(character), "a" + String(character) + "b")) }
        }
        for character in TeXTables.passedPunctuation.sorted() { lines.append(("pass " + String(character), "a" + String(character) + "b")) }
        if let escaped = try? TeXGate.plain(#"\ { } $ & % # _ ^ ~ < > [ ] ` -- '' ,,"#) { lines.append(("escapes", escaped.source)) }
        return lines
    }

    @Test("Every command, environment and character the gate lets through compiles with the export's preamble")
    func conformance() async throws {
        let lines = Self.conformanceLines()
        let head = LatexWriter.preamble.source + "\\begin{document}\n"
        let first = head.split(separator: "\n", omittingEmptySubsequences: false).count
        let tex = head + lines.map { $0.1 + "\\par" }.joined(separator: "\n") + "\n\\end{document}\n"
        let run = try await TeXRun.run(tex)
        defer { run.remove() }
        let failed = Set(run.errorLines.compactMap { line -> String? in
            let index = line - first
            return lines.indices.contains(index) ? lines[index].0 : "line \(line)"
        })
        #expect(failed.isEmpty, "\(failed.sorted()) \(run.errors.prefix(5))")
        #expect(run.log.contains("Output written"), "TeX produced a document")
    }
}

/// The hashtag kit's tools, run in the offline sandbox as an export runs them.
struct KitRun {
    nonisolated static let kit = ExportSpikeTests.kit
    nonisolated static let python = ExportSpikeTests.python
    nonisolated static let available = ExportSpikeTests.available

    static func environment(_ run: String) -> [String: String] {
        ["PATH": [TeXRun.texBin, "/opt/homebrew/bin", "/usr/bin", "/bin"].joined(separator: ":"), "PYTHON": python,
         "HOME": run, "TMPDIR": run, "LANG": "en_US.UTF-8", "TEXMFVAR": run + "/texmf-var",
         "TEXMFCONFIG": run + "/texmf-config", "shell_escape": "f", "openout_any": "p", "openin_any": "p"]
    }

    static func new(_ project: String, run: String, title: String, salt: String) async -> RunReport {
        await ProcessExecutor(runningFolder: nil).execute(
            .testing(python, ["-I", "-B", kit + "/kit.py", "new", project, "--title", title, "--salt", salt],
                     runFolder: run, readable: [kit]), onOutput: nil)
    }

    static func build(_ project: String, run: String) async -> RunReport {
        var limits = RunLimits.compute
        limits.seconds = 300
        return await ProcessExecutor(runningFolder: nil).execute(
            .testing("/bin/sh", [project + "/build.sh"], runFolder: run, limits: limits, environment: environment(run)),
            onOutput: nil)
    }

    /// Writes the document's files and regions into a project `kit.py new` made.
    static func write(_ document: ExportDocument, into project: String) throws {
        for file in HashtagWriter.files(document) {
            try Data(file.contents.utf8).write(to: URL(fileURLWithPath: project + "/" + file.path))
        }
        let regions = HashtagWriter.regions(document)
        let main = project + "/manuscript/main.tex", preamble = project + "/manuscript/preamble.tex"
        try Data(try HashtagWriter.firstMain(String(contentsOfFile: main, encoding: .utf8), regions: regions).utf8)
            .write(to: URL(fileURLWithPath: main))
        try Data(HashtagWriter.firstPreamble(String(contentsOfFile: preamble, encoding: .utf8), regions: regions).utf8)
            .write(to: URL(fileURLWithPath: preamble))
        try FileManager.default.removeItem(atPath: project + "/" + HashtagWriter.kitExample)
    }
}

@Suite("Export: the hashtag manuscript with the real kit", .serialized, .enabled(if: KitRun.available && TeXRun.available))
struct HashtagBuildTests {
    @Test("The fixture's manuscript passes the kit's build.sh: no error, every check PASS")
    func builds() async throws {
        let fixture = PreviewFixtures.make()
        try fixture.state.graph.setImported(fixture.conjecture.stableID, source: "Sylow, Theorem 1", in: fixture.problem)
        let citation = try #require(fixture.attemptA.sortedSteps[0].citations?.first)
        citation.matchedTitle = "Abstract algebra"
        citation.matchedAuthors = ["Dummit, David S.", "Foote, Richard M."]
        citation.matchedYear = 1991
        citation.resolvedURL = "https://zbmath.org/?q=an:0751.00001"
        var snapshot = ExportSnapshot.read(problem: fixture.problem, people: fixture.state.problems.personIDs())
        // Mathematics in what a step establishes and in a citation, typeset where each is printed.
        let attempt = try #require(snapshot.attempts.firstIndex { $0.id == fixture.attemptA.stableID })
        snapshot.attempts[attempt].steps[3].establishes = #"$q \mid p + 1$"#
        snapshot.attempts[attempt].steps[0].citations[0].text = "Dummit and Foote, on $p$-groups"
        let document = try ExportComposer.compose(snapshot, scope: .everyStatement,
                                                  verdicts: FormulaVerdicts.read(snapshot, renderer: MathRenderer.standard()))
        #expect(document.argument[3].source == #"$q \mid p + 1$"#)

        let run = ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path) + "/sangaku-kit-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: run) }
        let project = run + "/project"
        let made = await KitRun.new(project, run: run, title: HashtagWriter.kitTitle(snapshot.title),
                                    salt: HashtagWriter.salt(fixture.problem.stableID))
        #expect(made.end == .exited(0), "\(made.stderr.text)")
        try KitRun.write(document, into: project)
        let built = await KitRun.build(project, run: run)
        let output = built.stdout.text
        #expect(built.end == .exited(0), "\(output)")
        #expect(output.contains("LaTeX: 0 errors, 0 undefined references, 0 labels defined twice, 0 unresolved links"), "\(output)")
        for check in ["PASS tags", "PASS frozen files unchanged", "PASS every reference is defined",
                      "PASS no label is defined twice", "PASS every item has a label", "PASS every item lies in a subsection"] {
            #expect(output.contains(check), "\(check): \(output)")
        }
        if let folder = ProcessInfo.processInfo.environment["SANGAKU_PREVIEW_DIR"] {
            try? FileManager.default.removeItem(atPath: folder + "/export-hashtag.pdf")
            try? FileManager.default.copyItem(atPath: project + "/manuscript/main.pdf", toPath: folder + "/export-hashtag.pdf")
        }
    }
}
