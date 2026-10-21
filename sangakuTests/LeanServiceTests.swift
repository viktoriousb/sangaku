import Foundation
import SwiftData
import Testing
@testable import sangaku

extension LeanServiceTests {
    /// An elan folder whose pinned toolchain's `lean` is `/bin/sh`, never run: the executor is scripted.
    nonisolated static let elanHome: String = {
        let elan = FileManager.default.temporaryDirectory.appending(path: "sangaku-tests-elan").path
        let bin = elan + "/toolchains/" + LeanPin.folderName(LeanPin.toolchain) + "/bin"
        try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: bin + "/lean", withDestinationPath: "/bin/sh")
        return elan
    }()
}

/// A workspace that reads as fetched: the app's files, a record naming the pinned toolchain's `lean` and a Mathlib
/// library folder.
private func readyWorkspace() throws -> String {
    let root = FileManager.default.temporaryDirectory.appending(path: "sangaku-ws-\(UUID().uuidString)").path
    let workspace = LeanWorkspace(root: root, elanHome: LeanServiceTests.elanHome)
    try workspace.prepare()
    let library = root + "/.lake/packages/mathlib/.lake/build/lib/lean"
    try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: library + "/Mathlib.olean", contents: Data())
    let record = LeanWorkspaceRecord(environment: LeanFixtureCode.environment, lean: workspace.lean, leanPath: [library],
                                     fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
    try JSONColumn.encode(record)!.write(to: URL(fileURLWithPath: workspace.recordPath))
    return root
}

/// The kernel check's output for a module: every statement's declaration as a theorem, with the axioms given (standard
/// by default).
private func kernelOutput(_ plan: LeanModulePlan, axioms: [UUID: [String]] = [:]) -> String {
    plan.regions.map { region -> String in
        let object: [String: Any] = ["declaration": region.declaration, "kind": "theorem",
                                     "axioms": axioms[region.statementID] ?? ["propext"]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }.joined(separator: "\n") + "\n"
}

/// One of Lean's JSON messages on a module line.
private func leanMessage(_ line: Int, _ severity: String, _ text: String) -> String {
    let object: [String: Any] = ["pos": ["line": line, "column": 2], "severity": severity, "data": text,
                                 "fileName": "SangakuCheck.lean"]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Suite("Lean: checking and fidelity")
struct LeanServiceTests {
    private let fixture = PreviewFixtures.make()
    private let executor = ScriptedExecutor()
    private let lean: LeanService
    private let workspaceRoot: String

    init() throws {
        let tools = ToolRunner(executor: executor,
                               workRoot: FileManager.default.temporaryDirectory.appending(path: "sangaku-tests-work"))
        var values = ToolSettings.Values()
        workspaceRoot = try readyWorkspace()
        values.leanWorkspace = workspaceRoot
        lean = LeanService(context: fixture.state.container.mainContext, saves: fixture.state.saves,
                           problems: fixture.state.problems, tools: tools,
                           settings: ToolSettings(storage: .memory(values)), elanHome: Self.elanHome,
                           now: { Date(timeIntervalSinceReferenceDate: 800_300_000) })
    }

    private var context: ModelContext { fixture.state.container.mainContext }
    private let candidate = LeanSource(statementPart: "theorem main (p q : ℕ) (h : p < q) : p ≤ q", proofPart: ":= h.le")

    private func status(_ statement: Statement) -> StatementStatus {
        StatusRules.ownStatus(StatusInputs.make(for: statement, people: fixture.state.problems.personIDs()))
    }

    /// A draft by model A for a statement, on the main branch.
    private func draft(_ source: LeanSource, for statement: Statement) -> Message {
        let message = Message(author: .model(fixture.slotA.slotID), bodyLaTeX: "A draft.", kind: .leanDraft)
        context.insert(message)
        message.leanDraft = LeanDraft(statementID: statement.stableID, statementPart: source.statementPart,
                                      proofPart: source.proofPart)
        fixture.mainBranch.messages = (fixture.mainBranch.messages ?? []) + [message]
        return message
    }

    @Test("The module holds every checked statement's code, dependencies first, with the candidate in place")
    func module() throws {
        let lemma2 = fixture.lemmas[1]
        let plan = try lean.module(for: lemma2.stableID, candidate: .typed(candidate))
        let order = plan.regions.map(\.statementID)
        let checked = (fixture.problem.statements ?? []).filter { $0.leanResult != nil }.map(\.stableID)
        #expect(Set(order) == Set(checked))
        #expect(plan.region(for: lemma2.stableID)?.source == candidate)
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        for statement in fixture.problem.statements ?? [] {
            guard let mine = position[statement.stableID] else { continue }
            for used in statement.uses ?? [] {
                if let theirs = position[used.stableID] { #expect(theirs < mine, "\(used.label) before \(statement.label)") }
            }
        }
    }

    @Test("Invariants 12 and 14: Lean compiles the module shown, the app's kernel check reads it, and one check records every statement")
    func check() async throws {
        let lemma2 = fixture.lemmas[1]
        let lemma1 = fixture.lemmas[0]
        let plan = try lean.module(for: lemma2.stableID, candidate: .typed(candidate))
        executor.script(.exited(0), .exited(0, stdout: kernelOutput(plan, axioms: [lemma2.stableID: []])))
        try lean.check(lemma2.stableID, candidate: .typed(candidate), shown: plan.digest)
        try await waitUntil { lemma2.leanResult?.source == candidate.text }

        let compile = try #require(executor.jobs.first)
        let folder = (compile.files[0].path as NSString).deletingLastPathComponent
        #expect(compile.kind == .offline && compile.files.map(\.contents) == [plan.text])
        #expect(compile.arguments == ["--json", "-R", folder, "-o", folder + "/SangakuCheck.olean", folder + "/SangakuCheck.lean"])
        #expect(compile.grants.writable == [folder], "the module is written in the run folder, not the workspace")
        #expect(!compile.grants.readable.contains(where: { $0 == workspaceRoot || $0 == NSHomeDirectory() }),
                "only the toolchain and Mathlib are read")
        let kernel = try #require(executor.jobs.last)
        #expect(executor.jobs.count == 2 && kernel.arguments.prefix(2) == ["--run", kernel.files[0].path])
        #expect(kernel.files.map(\.contents) == [LeanCheckFiles.checkerSource] && kernel.files[0].path.hasSuffix("/AxiomCheck.lean"))
        #expect(Array(kernel.arguments.dropFirst(2)) == [folder + "/SangakuCheck.olean", "Mathlib"] + plan.regions.map(\.declaration))
        #expect(kernel.grants.readable.contains(folder) && !kernel.grants.writable.contains(folder),
                "the kernel check reads the compiled module and cannot change it")

        let result = try #require(lemma2.leanResult)
        #expect(result.axiomCheck == .ran(declaration: LeanNaming.declaration(for: lemma2.stableID), axioms: []))
        #expect(result.sourceAuthor == .human(fixture.you.personID) && result.checkedByID == fixture.you.stableID)
        #expect(lemma1.leanResult?.moduleDigest == plan.digest.hex, "the other statements were checked in the same run")
        #expect(status(lemma2) != .formallyVerified, "compiling is not enough: a person must confirm the statement")

        try lean.recordFidelity(.matches, statement: lemma2.stableID, seenLean: candidate.statementPart,
                                seenInformal: lemma2.statementLaTeX)
        #expect(status(lemma2) == .formallyVerified)
        let review = try #require(lemma2.fidelityReviews?.last)
        #expect(review.reviewerID == fixture.you.stableID && review.informalWording == lemma2.statementLaTeX)
    }

    @Test("Errors: no kernel check; the statements with errors and the one checked are recorded, the rest keep theirs")
    func errors() async throws {
        let lemma2 = fixture.lemmas[1]
        let lemma1 = fixture.lemmas[0]
        let before = try #require(lemma1.leanResult?.checkedAt)
        let plan = try lean.module(for: lemma2.stableID, candidate: .typed(candidate))
        let line = try #require(plan.region(for: lemma2.stableID)).firstSourceLine
        executor.script(.exited(1, stdout: leanMessage(line, "error", "unknown identifier 'h.le'") + "\n"))
        try lean.check(lemma2.stableID, candidate: .typed(candidate), shown: plan.digest)
        try await waitUntil { lemma2.leanResult?.source == candidate.text }
        #expect(executor.jobs.count == 1, "nothing compiled, so no kernel check")
        #expect(lemma2.leanResult?.errors.count == 1 && lemma2.leanResult?.axiomCheck == .notRun)
        #expect(lemma1.leanResult?.checkedAt == before, "a statement without errors keeps its last result")
        #expect(lean.lastFailure[lemma2.stableID] == nil)
    }

    @Test("Invariant 14: a module that changed since it was shown, or refused code, runs nothing")
    func refusals() throws {
        let lemma2 = fixture.lemmas[1]
        #expect(throws: VerificationError.changedSinceShown) {
            try lean.check(lemma2.stableID, candidate: .typed(candidate), shown: TextDigest(of: "something else"))
        }
        let bad = LeanSource(statementPart: "axiom cheat : False\ntheorem main : False", proofPart: ":= cheat")
        #expect(throws: VerificationError.gate(.banned("axiom"))) {
            try lean.module(for: lemma2.stableID, candidate: .typed(bad))
        }
        fixture.lemmas[0].leanResult?.leanStatementSource = "#exit\ntheorem main : True"
        fixture.lemmas[0].leanResult?.source = "#exit\ntheorem main : True\n:= trivial"
        #expect(throws: VerificationError.storedCodeRefused(label: "Lem 1", .banned("#exit"))) {
            try lean.module(for: lemma2.stableID, candidate: .typed(candidate))
        }
        #expect(executor.jobs.isEmpty)
    }

    @Test("Invariant 13: a proof names only statements its statement uses; a statement part names none")
    func references() throws {
        let lemma2 = fixture.lemmas[1]
        let unused = try #require((fixture.problem.statements ?? []).first {
            $0.stableID != lemma2.stableID && !lemma2.usesClosure.map(\.stableID).contains($0.stableID)
                && !$0.usesClosure.map(\.stableID).contains(lemma2.stableID)
        })
        let name = LeanNaming.declaration(for: unused.stableID)
        let inProof = LeanSource(statementPart: "theorem main : True", proofPart: ":= by\n  have := \(name)\n  trivial")
        #expect(throws: VerificationError.namesOtherStatement(label: lemma2.label, named: unused.label, inStatementPart: false)) {
            try lean.module(for: lemma2.stableID, candidate: .typed(inProof))
        }
        let inStatement = LeanSource(statementPart: "theorem main (h : \(name) = \(name)) : True", proofPart: ":= trivial")
        #expect(throws: VerificationError.namesOtherStatement(label: lemma2.label, named: unused.label, inStatementPart: true)) {
            try lean.module(for: lemma2.stableID, candidate: .typed(inStatement))
        }
        lemma2.uses = (lemma2.uses ?? []) + [unused]
        #expect(throws: Never.self) { try lean.module(for: lemma2.stableID, candidate: .typed(inProof)) }
        #expect(executor.jobs.isEmpty)
    }

    @Test("A check that says nothing reliable records nothing, keeps the last results, and says why")
    func failures() async throws {
        let lemma2 = fixture.lemmas[1]
        let before = lemma2.leanResult?.source
        let cases: [([RunReport], String)] = [
            ([RunReport(end: .timedOut, stdout: CappedText(text: ""), stderr: CappedText(text: ""), startedAt: .now,
                        seconds: 600)], "Lean did not finish in time"),
            ([.exited(1, stdout: leanMessage(1, "error", "unknown package 'Mathlib'") + "\n")], "outside the statements' code"),
            ([.exited(0, stdout: "not json\n")], "not its own messages"),
            ([.exited(1)], "an error it did not report"),
            ([.exited(0), .exited(1, stderr: "axiom check: (kernel) declaration type mismatch")], "kernel check did not accept"),
            ([.exited(0), .exited(0, stdout: "not json\n")], "could not be read"),
        ]
        for (reports, words) in cases {
            let plan = try lean.module(for: lemma2.stableID, candidate: .typed(candidate))
            reports.forEach { executor.script($0) }
            try lean.check(lemma2.stableID, candidate: .typed(candidate), shown: plan.digest)
            try await waitUntil { !lean.isChecking(problem: fixture.problem.stableID) }
            #expect(lemma2.leanResult?.source == before)
            #expect(lean.lastFailure[lemma2.stableID]?.contains(words) == true, "\(lean.lastFailure[lemma2.stableID] ?? "")")
            #expect(lean.lastFailure[lemma2.stableID]?.contains("nothing was recorded") == true)
        }
    }

    @Test("One check of a problem at a time; Stop records nothing")
    func stop() async throws {
        let lemma2 = fixture.lemmas[1]
        executor.hold()
        let plan = try lean.module(for: lemma2.stableID, candidate: .typed(candidate))
        try lean.check(lemma2.stableID, candidate: .typed(candidate), shown: plan.digest)
        #expect(lean.isChecking(problem: fixture.problem.stableID), "from the click, before Lean starts")
        #expect(throws: VerificationError.checkRunning) {
            try lean.check(lemma2.stableID, candidate: .typed(candidate), shown: plan.digest)
        }
        try await waitUntil { !executor.jobs.isEmpty }
        lean.stopCheck(problem: fixture.problem.stableID)
        try await waitUntil { lean.lastFailure[lemma2.stableID] != nil }
        #expect(lean.lastFailure[lemma2.stableID] == "The check was stopped; nothing was recorded.")
        #expect(lemma2.leanResult?.source != candidate.text && executor.jobs.count == 1)
    }

    @Test("Invariant 7: a draft is checked as stored, and its result says who wrote the code, edited unchanged or not")
    func draft() async throws {
        let lemma2 = fixture.lemmas[1]
        let message = draft(candidate, for: lemma2)
        let plan = try lean.module(for: lemma2.stableID, candidate: .draft(messageID: message.stableID))
        executor.script(.exited(0), .exited(0, stdout: kernelOutput(plan)))
        try lean.check(lemma2.stableID, candidate: .draft(messageID: message.stableID), shown: plan.digest)
        try await waitUntil { lemma2.leanResult?.draftMessageID == message.stableID }
        #expect(lemma2.leanResult?.sourceAuthor == .model(fixture.slotA.slotID))
        #expect(throws: VerificationError.noSuchDraft) {
            try lean.module(for: fixture.lemmas[2].stableID, candidate: .draft(messageID: message.stableID))
        }

        // Opened for editing and checked unchanged, the code is still the model's.
        let unchanged = LeanCandidate.typed(candidate, basedOn: .draft(messageID: message.stableID))
        let again = try lean.module(for: lemma2.stableID, candidate: unchanged)
        executor.script(.exited(0), .exited(0, stdout: kernelOutput(again)))
        try lean.check(lemma2.stableID, candidate: unchanged, shown: again.digest)
        try await waitUntil { executor.jobs.count == 4 && !lean.isChecking(problem: fixture.problem.stableID) }
        #expect(lemma2.leanResult?.sourceAuthor == .model(fixture.slotA.slotID) && lemma2.leanResult?.draftMessageID == message.stableID)

        // Changed, it is the person's.
        let edited = LeanSource(statementPart: candidate.statementPart, proofPart: ":= Nat.le_of_lt h")
        let changed = LeanCandidate.typed(edited, basedOn: .draft(messageID: message.stableID))
        let third = try lean.module(for: lemma2.stableID, candidate: changed)
        executor.script(.exited(0), .exited(0, stdout: kernelOutput(third)))
        try lean.check(lemma2.stableID, candidate: changed, shown: third.digest)
        try await waitUntil { lemma2.leanResult?.source == edited.text }
        #expect(lemma2.leanResult?.sourceAuthor == .human(fixture.you.personID) && lemma2.leanResult?.draftMessageID == nil)
    }

    @Test("Editing starts from a draft's own code, even code the gate refuses")
    func editingRefused() throws {
        let lemma2 = fixture.lemmas[1]
        let refused = LeanSource(statementPart: "import Mathlib\ntheorem main : True", proofPart: ":= trivial")
        let message = draft(refused, for: lemma2)
        #expect(throws: VerificationError.gate(.banned("import"))) {
            try lean.module(for: lemma2.stableID, candidate: .draft(messageID: message.stableID))
        }
        #expect(try lean.source(of: lemma2.stableID, candidate: .draft(messageID: message.stableID)) == refused)
    }

    @Test("Invariants 1 and 12: fidelity is the person's, on the texts they were shown")
    func fidelity() throws {
        let lemma3 = fixture.lemmas[2]
        let result = try #require(lemma3.leanResult)
        #expect(throws: VerificationError.changedSinceShown) {
            try lean.recordFidelity(.matches, statement: lemma3.stableID, seenLean: result.leanStatementSource + " ",
                                    seenInformal: lemma3.statementLaTeX)
        }
        #expect(throws: VerificationError.changedSinceShown) {
            try lean.recordFidelity(.matches, statement: lemma3.stableID, seenLean: result.leanStatementSource,
                                    seenInformal: "other wording")
        }
        #expect(throws: VerificationError.noLeanResult) {
            try lean.recordFidelity(.matches, statement: fixture.conjecture.stableID, seenLean: "x", seenInformal: "y")
        }
        try lean.recordFidelity(.differs, statement: lemma3.stableID, seenLean: result.leanStatementSource,
                                seenInformal: lemma3.statementLaTeX, comment: "  The bound is p ≤ q.  ")
        #expect(lemma3.fidelityReviews?.last?.verdict == .differs)
        #expect(lemma3.fidelityReviews?.last?.comment == "The bound is p ≤ q.")
        #expect(status(lemma3) != .formallyVerified)
    }

    @Test("Invariant 12: a person takes back their own review of a Lean statement; it stays and counts for nothing")
    func withdrawFidelity() throws {
        let lemma1 = fixture.lemmas[0]
        #expect(status(lemma1) == .formallyVerified, "the fixture's Lemma 1 has You's ✓")
        let reviews = lemma1.fidelityReviews?.count
        try lean.withdrawFidelity(statement: lemma1.stableID)
        #expect(status(lemma1) != .formallyVerified && lemma1.fidelityReviews?.count == reviews)
        #expect(LeanFacts.read(lemma1, people: fixture.state.problems.personIDs()).fidelity == .pending)
        #expect(throws: VerificationError.noFidelityToWithdraw) { try lean.withdrawFidelity(statement: lemma1.stableID) }

        // Someone else's review is theirs to withdraw.
        let theirs = FidelityReview(reviewer: fixture.mk.personID, leanStatementSource: lemma1.leanResult?.leanStatementSource ?? "",
                                    verdict: .matches)
        theirs.informalWording = lemma1.statementLaTeX
        theirs.createdAt = Date(timeIntervalSinceReferenceDate: 800_400_000)
        context.insert(theirs)
        lemma1.fidelityReviews = (lemma1.fidelityReviews ?? []) + [theirs]
        #expect(status(lemma1) == .formallyVerified)
        #expect(throws: VerificationError.noFidelityToWithdraw) { try lean.withdrawFidelity(statement: lemma1.stableID) }
        #expect(theirs.withdrawnAt == nil)
    }

    @Test("Without a fetched workspace nothing runs, and the words say what to do")
    func workspace() throws {
        let tools = ToolRunner(executor: executor, workRoot: FileManager.default.temporaryDirectory)
        let bare = LeanService(context: context, saves: fixture.state.saves, problems: fixture.state.problems,
                               tools: tools, settings: ToolSettings(storage: .memory()))
        let lemma2 = fixture.lemmas[1]
        let plan = try bare.module(for: lemma2.stableID, candidate: .typed(candidate))
        #expect(throws: VerificationError.workspace(LeanWorkspaceState.noFolder.refusal!)) {
            try bare.check(lemma2.stableID, candidate: .typed(candidate), shown: plan.digest)
        }
        let foreign = FileManager.default.temporaryDirectory.appending(path: "sangaku-foreign-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: foreign, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: foreign + "/thesis.tex", contents: Data())
        #expect(LeanWorkspace(root: foreign).state() == .foreign)
        let hidden = FileManager.default.temporaryDirectory.appending(path: "sangaku-hidden-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: hidden + "/.git", withIntermediateDirectories: true)
        #expect(LeanWorkspace(root: hidden).state() == .foreign, "hidden files are someone's too")
        #expect(throws: VerificationError.workspace(LeanWorkspaceState.foreign.refusal!)) {
            try LeanWorkspace(root: foreign).prepare()
        }
        #expect(executor.jobs.isEmpty)
    }

    @Test("Fetching Mathlib: the pinned steps with the network, then an offline check that Mathlib loads")
    func fetch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sangaku-fetch-\(UUID().uuidString)").path
        let elan = FileManager.default.temporaryDirectory.appending(path: "sangaku-elan-\(UUID().uuidString)").path
        let toolchain = elan + "/toolchains/" + LeanPin.folderName(LeanPin.toolchain) + "/bin"
        try FileManager.default.createDirectory(atPath: toolchain, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: toolchain + "/lean", withDestinationPath: "/bin/sh")
        var values = ToolSettings.Values()
        values.leanWorkspace = root
        values.paths[.elan] = "/bin/sh"
        let executor = ScriptedExecutor()
        let service = LeanService(context: context, saves: fixture.state.saves, problems: fixture.state.problems,
                                  tools: ToolRunner(executor: executor, workRoot: FileManager.default.temporaryDirectory),
                                  settings: ToolSettings(storage: .memory(values)), elanHome: elan)
        // What the scripted steps would have fetched, in a workspace already marked as the app's.
        try LeanWorkspace(root: root, elanHome: elan).prepare()
        let library = root + "/.lake/packages/mathlib/.lake/build/lib/lean"
        try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: library + "/Mathlib.olean", contents: Data())
        try Data(LeanPin.toolchain.utf8).write(to: URL(fileURLWithPath: root + "/.lake/packages/mathlib/lean-toolchain"))
        executor.script(.exited(), .exited(), .exited(stdout: "Lean (version 4.35.0, arm64-apple-darwin, Release)\n"),
                        .exited(stdout: library + "\n"), .exited())
        try service.fetchMathlib()
        try await waitUntil(timeout: .seconds(5)) { !service.fetch.isRunning }
        #expect(service.fetch.failure == nil)
        #expect(executor.jobs.map(\.arguments) == [["update"], ["exe", "cache", "get"], ["--version"],
                                                   ["env", "printenv", "LEAN_PATH"], ["--json", executor.jobs.last!.files[0].path]])
        #expect(executor.jobs.prefix(4).allSatisfy { $0.kind == .fetch } && executor.jobs.last?.kind == .offline)
        #expect(executor.jobs.last?.files.first?.contents == "import Mathlib\n", "the probe is the app's, not a person's code")
        let workspace = LeanWorkspace(root: root, elanHome: elan)
        #expect(executor.jobs.prefix(4).allSatisfy { $0.grants.writable == [root, elan] },
                "fetching writes the workspace and elan's folder, nothing else in the home folder")
        #expect(executor.jobs.first?.environment["XDG_CACHE_HOME"] == workspace.cacheHome
                && executor.jobs.first?.environment["MATHLIB_CACHE_DIR"] == workspace.cacheHome + "/mathlib")
        #expect(service.workspace.record?.leanPath == [library] && service.workspace.record?.environment.leanVersion == "4.35.0")
        let lakefile = try String(contentsOfFile: root + "/lakefile.toml", encoding: .utf8)
        #expect(lakefile.contains("rev = \"\(LeanPin.mathlibRev)\"") && !lakefile.contains("script"))
    }
}

/// Real Lean, the real sandbox, the app's kernel check and the real reader, on modules without Mathlib. Runs only where
/// the pinned toolchain is installed.
@Suite("Lean: a real check", .serialized)
struct RealLeanTests {
    private nonisolated static let toolchain = LeanWorkspace.defaultElanHome + "/toolchains/" + LeanPin.folderName(LeanPin.toolchain)
    private nonisolated static let available = FileManager.default.isExecutableFile(atPath: toolchain + "/bin/lean")

    private let setup = LeanCheckSetup(toolchainRoot: Self.toolchain, lean: Self.toolchain + "/bin/lean",
                                       leanPath: [Self.toolchain + "/lib/lean"])

    /// Compiles a plan and, if that was clean, runs the kernel check on it, both in the offline sandbox.
    private func run(_ plan: LeanModulePlan) async throws -> (compile: RunReport, axioms: RunReport?, folder: String) {
        let folder = ProcessExecutor.canonical(FileManager.default.temporaryDirectory.path) + "/sangaku-real-\(UUID().uuidString)"
        let executor = ProcessExecutor(runningFolder: nil)
        let problem = UUID()
        let compile = await executor.execute(.leanCheck(.typed(by: PersonID(UUID()), text: plan.text, at: .now), problem: problem,
                                                        setup: setup, runFolder: folder + "/compile", limits: .lean),
                                             onOutput: nil)
        guard compile.end == .exited(0) else { return (compile, nil, folder) }
        let checker = try #require(LeanCheckFiles.checkerSource)
        let axioms = await executor.execute(.leanAxioms(problem: problem, setup: setup,
                                                        compiledModule: folder + "/compile/" + LeanCheckFiles.compiled,
                                                        checker: checker, imports: plan.imports,
                                                        declarations: plan.regions.map(\.declaration),
                                                        runFolder: folder + "/axioms", limits: .lean),
                                            onOutput: nil)
        return (compile, axioms, folder)
    }

    @Test("Invariant 12: the kernel check reports each statement's axioms, sorry and dependencies included",
          .enabled(if: available))
    func realCheck() async throws {
        let (proved, open, user) = (UUID(), UUID(), UUID())
        let plan = LeanModulePlan([
            (proved, LeanSource(statementPart: "theorem main (n : Nat) : n + 0 = n", proofPart: ":= by simp")),
            (open, LeanSource(statementPart: "theorem main : 1 + 1 = 2", proofPart: ":= by\n  sorry")),
            (user, LeanSource(statementPart: "theorem main : 2 = 2",
                              proofPart: ":= by\n  have := \(LeanNaming.declaration(for: open))\n  rfl")),
        ], imports: [])
        let (compile, axioms, folder) = try await run(plan)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #expect(compile.end == .exited(0), "\(compile.stderr.text)")
        let kernel = try #require(axioms)
        #expect(kernel.end == .exited(0), "\(kernel.stderr.text)")
        let outcome = LeanOutputReader.read(stdout: compile.stdout.text, axioms: kernel.stdout.text, plan: plan)
        #expect(outcome.isReadable && outcome.axiomsChecked, "\(compile.stdout.text)\n\(kernel.stdout.text)")
        #expect(outcome.region(for: proved)?.axiomCheck == .ran(declaration: LeanNaming.declaration(for: proved), axioms: ["propext"]))
        #expect(outcome.region(for: open)?.axiomCheck == .ran(declaration: LeanNaming.declaration(for: open), axioms: ["sorryAx"]))
        #expect(outcome.region(for: open)?.sorryCount == 1)
        #expect(outcome.region(for: user)?.axiomCheck == .ran(declaration: LeanNaming.declaration(for: user), axioms: ["sorryAx"]),
                "a sorry in what a proof uses shows in its axioms")
    }

    @Test("Invariant 12: code that adds a theorem past the kernel and forges Lean's axiom report is caught by the kernel check",
          .enabled(if: available))
    func forgedReport() async throws {
        // Code the gate refuses, run here without it: a false `main` added with the kernel's check skipped, and an
        // elaborator that answers `#print axioms` with "does not depend on any axioms".
        let target = UUID()
        let name = LeanNaming.declaration(for: target)
        let forger = LeanSource(statementPart: """
            open Lean Elab Command
            run_cmd liftCoreM do
              withOptions (debug.skipKernelTC.set · true) do
                addDecl (.thmDecl { name := `\(name), levelParams := [], type := mkConst ``False,
                                    value := mkApp2 (mkConst ``Eq.refl [1]) (mkConst ``Nat) (mkNatLit 1) })
            @[command_elab Lean.Parser.Command.printAxioms] def forged : CommandElab := fun _ => do
              logInfo m!"'\(name)' does not depend on any axioms"
            theorem decoy : True
            """, proofPart: ":= trivial\n#print axioms \(name)")
        #expect(LeanGate.refusal(for: forger) != nil, "the gate refuses this code before it could ever run")
        let plan = LeanModulePlan([(target, forger)], imports: ["Lean"])
        let (compile, axioms, folder) = try await run(plan)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #expect(compile.end == .exited(0), "\(compile.stdout.text)\(compile.stderr.text)")
        #expect(compile.stdout.text.contains("does not depend on any axioms"), "Lean's own report is forged")
        let kernel = try #require(axioms)
        #expect(kernel.end == .exited(1) && kernel.stderr.text.contains("kernel"), "\(kernel.stdout.text)\(kernel.stderr.text)")
        let outcome = LeanOutputReader.read(stdout: compile.stdout.text, axioms: nil, plan: plan)
        #expect(outcome.region(for: target)?.axiomCheck == .notRun)
    }

    @Test("The kernel check refuses a compiled module that imports anything but what the app wrote",
          .enabled(if: available))
    func imports() async throws {
        let statement = UUID()
        let plan = LeanModulePlan([(statement, .trivial)], imports: [])
        let (compile, _, folder) = try await run(plan)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #expect(compile.end == .exited(0))
        let checker = try #require(LeanCheckFiles.checkerSource)
        let wrong = await ProcessExecutor(runningFolder: nil).execute(
            .leanAxioms(problem: UUID(), setup: setup, compiledModule: folder + "/compile/" + LeanCheckFiles.compiled,
                        checker: checker, imports: ["Mathlib"], declarations: plan.regions.map(\.declaration),
                        runFolder: folder + "/again", limits: .lean), onOutput: nil)
        #expect(wrong.end == .exited(1) && wrong.stderr.text.contains("imports"))
    }
}
