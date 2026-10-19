import Foundation
import SwiftData
import Testing
@testable import sangaku

@Suite("Save scheduler")
struct SaveSchedulerTests {
    @Test("Many changes in a quiet period make one save")
    func debounces() async throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let scheduler = SaveScheduler(context: container.mainContext, delay: .milliseconds(30))
        for i in 0..<20 {
            container.mainContext.insert(Problem(title: "P\(i)"))
            scheduler.markDirty()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(scheduler.saveCount == 1)
        #expect(!container.mainContext.hasChanges)
    }

    @Test("A failed save is kept, shown, retried, and cleared once a save succeeds")
    func failuresAreKeptAndRetried() async throws {
        struct DiskFull: LocalizedError { var errorDescription: String? { "The disk is full." } }
        var failing = true
        var attempts = 0
        let scheduler = SaveScheduler(hasChanges: { true }, save: {
            attempts += 1
            if failing { throw DiskFull() }
        }, delay: .milliseconds(10), retryDelay: .milliseconds(20))
        scheduler.flush()
        #expect(scheduler.lastError == "The disk is full.")
        #expect(scheduler.saveCount == 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(attempts >= 2, "a retry was scheduled")
        failing = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(scheduler.lastError == nil)
        #expect(scheduler.saveCount >= 1)
    }

    @Test func flushSavesNowAndOnlyWhenNeeded() throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let scheduler = SaveScheduler(context: container.mainContext, delay: .seconds(60))
        scheduler.flush()
        #expect(scheduler.saveCount == 0)
        container.mainContext.insert(Problem(title: "P"))
        scheduler.markDirty()
        scheduler.flush()
        #expect(scheduler.saveCount == 1)
        #expect(scheduler.lastError == nil)
    }
}

@Suite("Problem manager")
struct ProblemManagerTests {
    /// Held for the whole test: a `ModelContext` does not keep its container alive.
    private let container: ModelContainer
    private let manager: ProblemManager

    init() throws {
        container = try ModelContainerFactory.make(.inMemory)
        manager = ProblemManager(context: container.mainContext,
                                 saves: SaveScheduler(context: container.mainContext, delay: .seconds(60)))
    }

    @Test("A fresh store is empty: first launch shows no problems")
    func startsEmpty() throws {
        let state = AppState(storage: .inMemory)
        #expect(try state.container.mainContext.fetchCount(FetchDescriptor<Problem>()) == 0)
    }

    @Test func createProblemMakesAMainBranchAndAPerson() throws {
        let problem = manager.createProblem(title: "Groups of order 36")
        #expect(problem.branches?.count == 1)
        #expect(problem.mainBranchID == problem.branches?.first?.stableID)
        #expect(problem.createdByID == manager.me().stableID)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Person>()) == 1)
        #expect(manager.problem(id: problem.stableID) === problem)
    }

    @Test func conventionsValidateAndStoreCanonicalMacros() throws {
        let problem = manager.createProblem()
        let entry = try manager.addConvention(to: problem, symbolLaTeX: #"\Z"#, meaning: "the integers",
                                              macroDefinition: #"\newcommand\Z{\mathbb{Z}}"#)
        #expect(entry.macroDefinition == #"\newcommand{\Z}{\mathbb{Z}}"#)
        #expect(throws: NotationError.self) {
            try manager.addConvention(to: problem, symbolLaTeX: "x", meaning: "", macroDefinition: #"\def\x{y}"#)
        }
        #expect(throws: NotationError.self) {
            try manager.addConvention(to: problem, symbolLaTeX: "x", meaning: "", macroDefinition: "not a macro")
        }
        let plain = try manager.addConvention(to: problem, symbolLaTeX: "G", meaning: "a finite group", macroDefinition: "")
        #expect(plain.macroDefinition == nil)
    }

    @Test("Notation changes reach rendering through a new fingerprint")
    func notationFeedsTheMathContext() throws {
        let problem = manager.createProblem()
        let before = manager.mathContext(for: problem)
        let entry = try manager.addConvention(to: problem, symbolLaTeX: #"\Z"#, meaning: "", macroDefinition: #"\newcommand{\Z}{\mathbb{Z}}"#)
        let after = manager.mathContext(for: problem)
        #expect(before.macros.fingerprint != after.macros.fingerprint)
        #expect(try after.macros.expand(#"\Z"#).get() == #"\mathbb{Z}"#)
        // Toggling "include in context" changes prompts only, not rendering.
        manager.setIncludeInContext(entry, false)
        #expect(manager.mathContext(for: problem).macros.fingerprint == after.macros.fingerprint)
        #expect(!manager.notation(for: problem).promptBlock().contains("mathbb"))
    }

    @Test("Preamble import upserts by name and reports what it skipped")
    func importsPreambles() throws {
        let problem = manager.createProblem()
        let first = manager.importPreamble(#"""
        \newcommand{\Z}{\mathbb{Z}}
        \newcommand{\abs}[1]{\lvert #1\rvert}
        \def\N{\mathbb{N}}
        """#, into: problem)
        #expect(first.added == ["Z", "abs"])
        #expect(first.skipped.count == 1)
        #expect(problem.sortedNotation.map(\.symbolLaTeX) == [#"\Z"#, #"\abs{x}"#])

        let second = manager.importPreamble(#"\renewcommand{\Z}{\mathbf{Z}}\newcommand{\abs}[1]{\lvert #1\rvert}"#, into: problem)
        #expect(second.added.isEmpty)
        #expect(second.updated == ["Z"])
        #expect(problem.notation?.count == 2)
        #expect(try manager.mathContext(for: problem).macros.expand(#"\Z"#).get() == #"\mathbf{Z}"#)
    }

    @Test func deletingAProblemRemovesItsNotation() throws {
        let problem = manager.createProblem()
        manager.importPreamble(#"\newcommand{\Z}{\mathbb{Z}}"#, into: problem)
        manager.delete(problem)
        try container.mainContext.save()
        #expect(try container.mainContext.fetchCount(FetchDescriptor<NotationEntry>()) == 0)
    }
}

@Suite("Window state")
struct WindowStateTests {
    @Test func selectingAProblemResetsTheBranchToMain() throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let manager = ProblemManager(context: container.mainContext, saves: SaveScheduler(context: container.mainContext))
        let problem = manager.createProblem()
        let window = WindowState()
        window.selectedBranchID = UUID()
        window.select(problem: problem)
        #expect(window.selectedProblemID == problem.stableID)
        #expect(window.selectedBranchID == problem.mainBranchID)
        window.select(problem: nil)
        #expect(window.selectedProblemID == nil)
    }
}

@Suite("Window flows")
struct WindowFlowTests {
    private let container: ModelContainer
    private let manager: ProblemManager

    init() throws {
        container = try ModelContainerFactory.make(.inMemory)
        manager = ProblemManager(context: container.mainContext, saves: SaveScheduler(context: container.mainContext, delay: .seconds(60)))
    }

    @Test("New Problem selects it, shows the thread and opens the editor, from any view")
    func createProblem() {
        let window = WindowState()
        window.activeView = .review
        window.createProblem(using: manager)
        #expect(window.selectedProblemID != nil)
        #expect(window.activeView == .thread)
        #expect(window.isEditingProblem)
    }

    @Test func deletingTheShownProblemClearsTheSelection() throws {
        let window = WindowState()
        window.createProblem(using: manager)
        let problem = try #require(manager.problem(id: window.selectedProblemID))
        window.delete(problem, using: manager)
        #expect(window.selectedProblemID == nil)
    }

    @Test("Deleting or editing a convention changes the macros at once, before any save")
    func conventionChangesApplyImmediately() throws {
        let problem = manager.createProblem()
        let entry = try manager.addConvention(to: problem, symbolLaTeX: #"\Z"#, meaning: "", macroDefinition: #"\newcommand{\Z}{\mathbb{Z}}"#)
        try manager.updateConvention(entry, symbolLaTeX: #"\Z"#, meaning: "integers", macroDefinition: #"\newcommand{\Z}{\mathbf{Z}}"#,
                                     includeInContext: true)
        #expect(try manager.mathContext(for: problem).macros.expand(#"\Z"#).get() == #"\mathbf{Z}"#)
        manager.deleteConvention(entry)
        #expect(manager.mathContext(for: problem).macros.isEmpty)
        #expect(manager.notation(for: problem).rows.isEmpty)
    }
}
