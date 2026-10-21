import Foundation
import Testing
@testable import sangaku

@Suite("Lean: source, gate and module")
struct LeanSourceTests {
    @Test("A source is normalized and joined the same way every time")
    func shape() {
        let source = LeanSource(statementPart: "\r\ntheorem main : True  \r\n", proofPart: ":= trivial\n\n")
        #expect(source.statementPart == "theorem main : True" && source.proofPart == ":= trivial")
        #expect(source.text == "theorem main : True\n:= trivial")
    }

    @Test("Invariant 12: the gate lets mathematics through and refuses code that programs Lean, before anything runs")
    func gate() {
        func refusal(_ statement: String, _ proof: String = ":= trivial") -> LeanGate.Refusal? {
            LeanGate.refusal(for: LeanSource(statementPart: statement, proofPart: proof))
        }
        // What checked code looks like.
        #expect(refusal("theorem main : True") == nil)
        #expect(refusal("lemma main (n : ℕ) : n = n", ":= rfl") == nil)
        #expect(refusal("def f := 1\ntheorem main : f = 1", ":= rfl") == nil)
        #expect(refusal("-- import is fine in a comment\ntheorem main : True") == nil)
        #expect(refusal("theorem main (f : ℕ → ℕ) (s : Set ℕ) (h' : s = s) : f '' s = f ⁻¹' (f '' s) ∨ True",
                        ":= Or.inr trivial") == nil, "image, preimage and primes are not character literals")
        #expect(refusal("open scoped Real in\ntheorem main : True") == nil)
        #expect(refusal("local instance : Fact (1 < 2) := ⟨by norm_num⟩\ntheorem main : True") == nil)
        #expect(refusal("@[simp] lemma helper : 1 + 1 = 2 := rfl\nattribute [local instance] Nat.instInhabited\ntheorem main : True") == nil)
        #expect(refusal("theorem main : True", ":= by\n  set_option maxHeartbeats 400000 in\n  trivial") == nil)

        #expect(refusal("", "") == .empty)
        #expect(refusal("theorem main : True\u{202E}") == .hiddenCharacter("U+202E"))
        #expect(refusal("/- open comment\ntheorem main : True") == .unbalanced)
        // No literal can hide code from the gate.
        #expect(refusal("theorem main : True", ":= by\n  exact \"end\" |>.length |> fun _ => trivial") == .literal("\""))
        #expect(refusal("theorem main : True", ":= by\n  have := '\"'\n  have := '\"'\n  trivial") == .literal("'"),
                "two quote characters cannot blank what is between them")
        #expect(refusal("theorem main : True", ":= by\n  have := 'a'\n  trivial") == .literal("'"))
        #expect(refusal("theorem main : True", ":= by\n  have := `Nat\n  trivial") == .literal("`"))
        #expect(refusal("def «end» := 1\ntheorem main : True") == .literal("«"))
        // Commands and words that program Lean, leave the namespace or add axioms.
        #expect(refusal("import Mathlib.Tactic\ntheorem main : True") == .banned("import"))
        #expect(refusal("theorem main : True", ":= by\n  trivial\nend Sangaku.S1\ntheorem x : False := sorry") == .banned("end"))
        #expect(refusal("namespace X\ntheorem main : True") == .banned("namespace"))
        #expect(refusal("axiom cheat : False\ntheorem main : False") == .banned("axiom"))
        #expect(refusal("theorem main : True", ":= by\n  run_tac pure ()") == .banned("run_tac"))
        #expect(refusal("theorem main : True", ":= by\n  exact (trivial).run_tac") == .banned("run_tac"), "a word after a dot")
        #expect(refusal("syntax foo : term\ntheorem main : True") == .banned("syntax"))
        #expect(refusal("def _root_.cheat := 1\ntheorem main : True") == .banned("_root_"))
        #expect(refusal("partial def f : ℕ → ℕ := f\ntheorem main : True") == .banned("partial"))
        #expect(refusal("deriving instance Repr for Nat\ntheorem main : True") == .banned("deriving"))
        #expect(refusal("theorem main : True", ":= trivial\n#print axioms main") == .banned("#print"))
        #expect(refusal("theorem main : True", ":= trivial\n#exit") == .banned("#exit"))
        #expect(refusal("@[implemented_by x] def y := 1\ntheorem main : True") == .banned("implemented_by"))
        // Lean's own namespaces, however they are reached.
        #expect(refusal("open Lean Elab Command in\ntheorem main : True") == .banned("Lean"))
        #expect(refusal("theorem main : True", ":= by\n  exact Lean.Elab.Term.elabTerm") == .banned("Lean"))
        #expect(refusal("theorem main : True", ":= by\n  have := IO.FS.readFile\n  trivial") == .banned("IO"))
        // Elaborators, global instances, scoped declarations and options.
        #expect(refusal("@[command_elab foo] def f := 1\ntheorem main : True") == .attribute("command_elab"))
        #expect(refusal("@[simp, term_elab foo] def f := 1\ntheorem main : True") == .attribute("term_elab"))
        #expect(refusal("instance : Inhabited ℕ := ⟨0⟩\ntheorem main : True") == .globalInstance)
        #expect(refusal("@[instance] def i : Inhabited ℕ := ⟨0⟩\ntheorem main : True") == .globalInstance)
        #expect(refusal("attribute [instance] Nat.instInhabited\ntheorem main : True") == .globalInstance)
        #expect(refusal("scoped instance : Inhabited ℕ := ⟨0⟩\ntheorem main : True") == .banned("scoped"))
        #expect(refusal("set_option debug.skipKernelTC true in\ntheorem main : True") == .option("debug.skipKernelTC"))
        #expect(refusal("set_option autoImplicit true in\ntheorem main : True") == .option("autoImplicit"))
        // The shape: a target, last in the statement part, with the proof after it.
        #expect(refusal("theorem main : True\ndef later := 1") == .noTarget, "the target is the last declaration")
        #expect(refusal("@[simp] theorem main : True") == .noTarget, "no attribute on the target")
        #expect(refusal("private theorem main : True") == .noTarget)
        #expect(refusal("theorem mainly : True") == .noTarget)
        #expect(refusal("theorem main : True := trivial") == .assignInStatement)
        #expect(refusal("theorem main : True", "by trivial") == .proofMustStartWithAssign)
    }

    @Test("Names of other statements are found wherever they are written")
    func references() {
        #expect(LeanGate.references(in: "exact Sangaku.S1a2b3c4d5e6f.main") == ["1a2b3c4d5e6f"])
        #expect(LeanGate.references(in: "have := S1a2b3c4d5e6f.helper\n-- S0000000000ff.main in a comment") == ["1a2b3c4d5e6f"])
        #expect(LeanGate.references(in: "exact S1A2B3C4D5E6F.main ∘ Sx.main").isEmpty)
    }

    @Test("Comments are read past, nested ones included; sorries are found where they are")
    func lexicon() {
        let text = "/- a /- nested -/ sorry -/ theorem main : True\n:= by\n  -- sorry here is a comment\n  sorry"
        let (code, balanced) = LeanLexicon.blank(text)
        #expect(balanced && code.components(separatedBy: "\n").count == 4)
        #expect(LeanLexicon.sorries(in: text) == [LeanLocation(line: 4, column: 2)])
        #expect(LeanLexicon.sorries(in: "exact sorryAx _ ∨ admit") == [LeanLocation(line: 1, column: 18)])
        #expect(LeanLexicon.tokens(in: "(x).Lean.Elab ∘ h'").map(\.text) == ["x", ".Lean.Elab", "h'"])
    }

    @Test("The module: a fixed header, then each statement in its namespace in the order given")
    func module() throws {
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let plan = LeanModulePlan([(first, .trivial), (second, LeanSource(statementPart: "theorem main : 1 = 1",
                                                                            proofPart: ":= rfl"))])
        #expect(plan.text == """
        import Mathlib
        set_option autoImplicit false
        set_option relaxedAutoImplicit false

        namespace Sangaku.S111111111111
        theorem main : True
        := trivial
        end Sangaku.S111111111111

        namespace Sangaku.S222222222222
        theorem main : 1 = 1
        := rfl
        end Sangaku.S222222222222

        """)
        let regions = plan.regions
        #expect(regions.map(\.span) == [5...8, 10...13] && regions.map(\.firstSourceLine) == [6, 11])
        #expect(regions[1].declaration == "Sangaku.S222222222222.main" && plan.imports == ["Mathlib"])
        let other = LeanModulePlan([(second, .trivial), (first, .trivial)])
        #expect(plan.digest == TextDigest(of: plan.text) && other.digest != plan.digest, "order is part of the module")
        #expect(!plan.text.contains("#print"), "nothing in the module reports axioms")
    }
}

@Suite("Lean: reading a check")
struct LeanOutputTests {
    private let first = UUID()
    private let second = UUID()

    private var plan: LeanModulePlan {
        LeanModulePlan([(first, .trivial),
                        (second, LeanSource(statementPart: "theorem main : 2 = 2", proofPart: ":= by\n  sorry"))])
    }

    private func line(_ line: Int, _ severity: String, _ data: String, kind: String? = nil, column: Int = 0) -> String {
        var object: [String: Any] = ["fileName": "/w/SangakuCheck.lean", "pos": ["line": line, "column": column],
                                     "endPos": ["line": line, "column": column + 4], "severity": severity, "data": data,
                                     "caption": "", "isSilent": false, "keepFullRange": false]
        object["kind"] = kind ?? "[anonymous]"
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The kernel check's lines: a declaration, its kind and its axioms.
    private func kernel(_ entries: [(String, String, [String])]) -> String {
        entries.map { declaration, kind, axioms in
            let object: [String: Any] = ["declaration": declaration, "kind": kind, "axioms": axioms]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
    }

    @Test("Invariant 12: axioms come only from the kernel check, one line per declaration, as a theorem")
    func axioms() {
        let plan = plan
        let firstName = plan.regions[0].declaration
        let secondName = plan.regions[1].declaration
        let compile = line(plan.regions[1].firstSourceLine, "warning", "declaration uses `sorry`", kind: "hasSorry", column: 8)
        let outcome = LeanOutputReader.read(stdout: compile, axioms: kernel([(firstName, "theorem", []),
                                                                             (secondName, "theorem", ["sorryAx"])]),
                                            plan: plan)
        #expect(outcome.isReadable && outcome.axiomsChecked)
        #expect(outcome.region(for: first)?.axiomCheck == .ran(declaration: firstName, axioms: []))
        #expect(outcome.region(for: second)?.axiomCheck == .ran(declaration: secondName, axioms: ["sorryAx"]))
        #expect(outcome.region(for: second)?.sorryCount == 1)
        #expect(outcome.region(for: second)?.sorryLocations == [LeanLocation(line: 3, column: 2)])
        #expect(outcome.region(for: second)?.messages.first?.line == 1, "lines are counted in the statement's code")

        func checks(_ axioms: String?) -> [AxiomCheck?] {
            let outcome = LeanOutputReader.read(stdout: "", axioms: axioms, plan: plan)
            return [outcome.region(for: first)?.axiomCheck, outcome.region(for: second)?.axiomCheck]
        }
        #expect(checks(nil) == [.notRun, .notRun], "no kernel check, no axioms")
        #expect(checks(kernel([(firstName, "theorem", [])])) == [.notRun, .notRun], "a declaration missing")
        #expect(checks(kernel([(firstName, "theorem", []), (firstName, "theorem", []), (secondName, "theorem", [])]))
                == [.notRun, .notRun], "a declaration twice")
        #expect(checks(kernel([(firstName, "theorem", []), (secondName, "theorem", [])]) + "not json\n")
                == [.notRun, .notRun], "a line that is not the kernel check's")
        #expect(checks(kernel([(firstName, "other", []), (secondName, "theorem", [])]))
                == [.notRun, .ran(declaration: secondName, axioms: [])], "only a theorem counts")
        #expect(checks(kernel([(firstName, "theorem", ["two words"]), (secondName, "missing", [])])) == [.notRun, .notRun])
        // Text that looks like an axiom report in Lean's own messages is only a message.
        let forged = LeanOutputReader.read(stdout: line(plan.regions[0].firstSourceLine, "information",
                                                        "'\(firstName)' does not depend on any axioms"),
                                           axioms: nil, plan: plan)
        #expect(forged.region(for: first)?.axiomCheck == .notRun && forged.region(for: first)?.messages.count == 1)
    }

    @Test("A module error or a line that is not Lean's JSON makes the whole check unreadable")
    func readability() {
        let plan = plan
        #expect(LeanOutputReader.read(stdout: "", axioms: nil, plan: plan).isReadable)
        let header = LeanOutputReader.read(stdout: line(1, "error", "unknown module prefix 'Mathlib'"), axioms: nil, plan: plan)
        #expect(!header.isReadable && header.moduleErrors.count == 1)
        #expect(!LeanOutputReader.read(stdout: "uncaught exception: out of memory\n", axioms: nil, plan: plan).isReadable)
        let odd = LeanOutputReader.read(stdout: line(plan.regions[0].firstSourceLine, "fatal", "?"), axioms: nil, plan: plan)
        #expect(odd.region(for: first)?.errorCount == 1 && odd.hasErrors, "an unknown severity counts as an error")
        for region in plan.regions {
            for wrapperLine in [region.span.lowerBound, region.span.upperBound] {
                let wrapper = LeanOutputReader.read(stdout: line(wrapperLine, "error", "invalid 'end'"), axioms: nil,
                                                    plan: plan)
                #expect(wrapper.isReadable && wrapper.region(for: region.statementID)?.messages.first?.line == 0,
                        "a message on a statement's namespace lines is the statement's, at line 0")
            }
        }
        // A line separator inside a message's text is not the end of Lean's line.
        let raw = "{\"pos\":{\"line\":\(plan.regions[0].firstSourceLine),\"column\":0},\"severity\":\"error\",\"data\":\"a\u{2028}b\u{85}c\"}"
        let separated = LeanOutputReader.read(stdout: raw, axioms: nil, plan: plan)
        #expect(separated.isReadable && separated.region(for: first)?.messages.first?.text == "a\u{2028}b\u{85}c")
    }
}

@Suite("Lean: what a stored result counts for")
struct LeanStatusTests {
    private let fixture = PreviewFixtures.make()

    private func status(_ statement: Statement) -> StatementStatus {
        StatusRules.ownStatus(StatusInputs.make(for: statement, people: fixture.state.problems.personIDs()))
    }

    @Test("Invariants 1 and 12: a result counts only on its own source and declaration, with fidelity on this wording")
    func storedResult() throws {
        let lemma = fixture.lemmas[1]
        lemma.recordLeanCheck(.trivial, axioms: [])
        #expect(status(lemma) != .formallyVerified, "no fidelity review yet")
        lemma.confirmLean(by: fixture.you.personID)
        #expect(status(lemma) == .formallyVerified, "no axioms at all, read from the axiom line")
        let result = try #require(lemma.leanResult)

        result.source += "\n-- edited after the check"
        #expect(status(lemma) != .formallyVerified, "the digest no longer matches")
        lemma.recordLeanCheck(.trivial, axioms: [])

        result.axiomCheckedDeclaration = LeanNaming.declaration(for: fixture.lemmas[0].stableID)
        #expect(status(lemma) != .formallyVerified, "a result read for another statement")
        result.axiomCheckedDeclaration = ""
        #expect(status(lemma) != .formallyVerified, "the axiom line did not report")
        lemma.recordLeanCheck(.trivial, axioms: [])
        #expect(status(lemma) == .formallyVerified)

        lemma.statementLaTeX += " (reworded)"
        #expect(status(lemma) != .formallyVerified, "fidelity was given on other wording")
    }

    @Test("Invariant 13: a result counts only while its proof names what its statement uses, and its statement part none")
    func references() throws {
        let lemma = fixture.lemmas[1]
        let other = fixture.lemmas[0]
        lemma.uses = (lemma.uses ?? []).filter { $0.stableID != other.stableID }
        other.uses = (other.uses ?? []).filter { $0.stableID != lemma.stableID }
        let name = LeanNaming.declaration(for: other.stableID)
        lemma.recordLeanCheck(LeanSource(statementPart: "theorem main : True", proofPart: ":= by\n  have := \(name)\n  trivial"),
                              axioms: [])
        lemma.confirmLean(by: fixture.you.personID)
        #expect(status(lemma) != .formallyVerified, "the proof names a statement this one does not use")
        lemma.uses = (lemma.uses ?? []) + [other]
        #expect(status(lemma) == .formallyVerified)
        lemma.recordLeanCheck(LeanSource(statementPart: "theorem main (h : \(name) = \(name)) : True", proofPart: ":= trivial"),
                              axioms: [])
        lemma.confirmLean(by: fixture.you.personID)
        #expect(status(lemma) != .formallyVerified, "what a statement says never rests on another statement's code")
    }

    @Test("Fidelity: the latest person's review stands; a tie confirms only if all agree; models count for nothing")
    func fidelityRule() {
        let at = Date(timeIntervalSinceReferenceDate: 1)
        let person = UUID()
        func review(_ verdict: FidelityVerdict, by reviewer: UUID? = nil, at date: Date = at,
                    lean: String = "S", informal: String = "I") -> FidelityRule.Review {
            FidelityRule.Review(reviewer: reviewer ?? person, leanStatement: lean, informal: informal, verdict: verdict,
                                createdAt: date)
        }
        func confirmed(_ reviews: [FidelityRule.Review]) -> Bool {
            FidelityRule.confirmed(reviews, people: [person], leanStatement: "S", informal: "I")
        }
        #expect(confirmed([review(.matches)]))
        #expect(!confirmed([review(.matches), review(.differs, at: at.addingTimeInterval(1))]))
        #expect(confirmed([review(.differs), review(.matches, at: at.addingTimeInterval(1))]))
        #expect(!confirmed([review(.matches), review(.differs)]), "a tie is the less trusting verdict")
        #expect(!confirmed([review(.matches, by: UUID())]), "an ID that is no person")
        #expect(!confirmed([review(.matches, lean: "S2")]) && !confirmed([review(.matches, informal: "I2")]))
        var withdrawn = review(.matches, at: at.addingTimeInterval(2))
        withdrawn.withdrawn = true
        #expect(!confirmed([withdrawn]) && confirmed([review(.matches), withdrawn]), "a withdrawn review counts for nothing")
        #expect(!confirmed([review(.matches), review(.differs, at: at.addingTimeInterval(1)), withdrawn]))
        #expect(!FidelityRule.confirmed([review(.matches, lean: "")], people: [person], leanStatement: "",
                                        informal: "I"))
    }
}
