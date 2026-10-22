import Foundation
import Testing
@testable import sangaku

@Suite("Export: the Lean project")
struct ExportLeanProjectTests {
    private let fixture = PreviewFixtures.make()

    private func files() throws(LeanProjectError) -> [String: String] {
        let snapshot = ExportSnapshot.read(problem: fixture.problem, people: fixture.state.problems.personIDs())
        return Dictionary(uniqueKeysWithValues: try LeanProjectWriter.files(snapshot).map { ($0.path, $0.contents) })
    }

    private var library: String { LeanProjectWriter.libraryName(fixture.problem.stableID) }

    @Test("The module is byte for byte the one the checks compiled, from checked code only")
    func module() throws {
        let made = try files()
        let module = try #require(made[library + ".lean"])
        #expect(TextDigest(of: module).hex == fixture.lemmas[0].leanResult?.moduleDigest, "the digest the results record")
        for lemma in fixture.lemmas {
            #expect(module.contains("namespace " + LeanNaming.namespace(for: lemma.stableID)))
        }
        let lemma6 = try #require(fixture.problem.statements?.first { $0.label == "Lem 6" })
        #expect(!module.contains(LeanNaming.namespace(for: lemma6.stableID)), "no draft, no unchecked statement")
        #expect(made["lean-toolchain"] == LeanPin.toolchain + "\n")
        #expect(made[".gitignore"] == ".lake/\n")
        let lakefile = try #require(made["lakefile.toml"])
        #expect(lakefile.contains("rev = \"\(LeanPin.mathlibRev)\"") && lakefile.contains("name = \"\(library)\""))
    }

    @Test("The README says \"verified in Lean\" only for a statement whose check is rule 2, and names roles only")
    func readme() throws {
        let readme = try #require(try files()["README.md"])
        let rows = readme.split(separator: "\n").filter { $0.hasPrefix("| Lem") }
        #expect(rows.count == 5)
        #expect(rows.filter { $0.contains("| verified in Lean") }.map { String($0.prefix(8)) } == ["| Lem 1 ", "| Lem 5 "])
        #expect(rows.first { $0.hasPrefix("| Lem 4") }?.contains("uses sorry or an axiom beyond the standard three") == true)
        #expect(rows.allSatisfy { $0.contains("a language model") && $0.contains("2026-05-09, in this module") })
        #expect(readme.contains("## Use of AI") && readme.contains("Only Lem 1 and Lem 5 are verified in Lean"))
        for name in ["MK", "You ", "Model A", "Claude", "Opus", "Anthropic"] { #expect(!readme.contains(name), "\(name)") }
    }

    @Test("Markdown in a label or title is shown as typed, never a link")
    func markdown() throws {
        #expect(try LeanProjectWriter.markdown("[x](https://a.b) <b>|", label: "x") == #"\[x\]\(https://a\.b\) \<b\>\|"#)
        #expect(throws: LeanProjectError.hidden(label: "x")) { try LeanProjectWriter.markdown("a\u{202E}b", label: "x") }
    }

    @Test("Checked code that the gate now refuses, or that names a statement it does not use, refuses the export")
    func refusals() throws {
        let lemma2 = fixture.lemmas[1]
        let result = try #require(lemma2.leanResult)
        let (original, digest) = (result.source, result.checkedDigest)
        // As if the code had been checked by an earlier app whose gate let it through.
        func store(_ source: String) {
            result.source = source
            result.checkedDigest = TextDigest(of: source).hex
        }
        store(result.leanStatementSource + "\n" + #":= by exact absurd "x""#)
        #expect(throws: LeanProjectError.codeRefused(label: "Lem 2", .literal("\""))) { try files() }

        // Lem 2 uses nothing, so its proof may not name Lem 1's code.
        store(result.leanStatementSource + "\n:= Sangaku.S" + LeanNaming.short(fixture.lemmas[0].stableID) + ".main")
        #expect(throws: LeanProjectError.namesOtherStatement(label: "Lem 2", named: "Lem 1")) { try files() }

        // Code changed since its check no longer counts as checked: it is left out, and the README says the module
        // is not the one checked.
        result.source = original + "\n"
        let made = try files()
        #expect(made["README.md"]?.contains("| Lem 2 |") == false)
        #expect(made["README.md"]?.contains("in an earlier module") == true)
        (result.source, result.checkedDigest) = (original, digest)
        #expect(throws: Never.self) { try files() }
    }

    @Test("Nothing checked: nothing to export")
    func nothingChecked() {
        for statement in fixture.problem.statements ?? [] { statement.leanResult = nil }
        #expect(throws: LeanProjectError.nothingChecked) { try files() }
    }
}
