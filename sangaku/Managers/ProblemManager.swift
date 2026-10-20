import Foundation
import SwiftData

nonisolated struct NotationError: Error, Hashable, Sendable {
    var message: String
}

/// What an import did, shown to the user before and after confirming.
nonisolated struct PreambleImportReport: Hashable, Sendable {
    var added: [String] = []
    var updated: [String] = []
    var skipped: [SkippedDefinition] = []
}

/// Problems, the pinned statement (the problem's theorem), the notation registry, the provider policy and model
/// slots. Every mutation of these goes through here and ends in one `markDirty()`; views read through `@Query` and
/// the models' relationships. Lemmas, claims and dependencies are `StatementGraph`'s.
@Observable
final class ProblemManager {
    /// Bumped by every change to a problem's notation that can change its macros. `mathContext(for:)` reads
    /// it, so views that render math recompute their macros exactly when they change.
    private(set) var notationRevisions: [UUID: Int] = [:]
    /// Bumped when only what goes into prompts changes (`includeInContext`, the statement, a slot's model or role,
    /// a new slot), which never re-renders math.
    private(set) var contextRevisions: [UUID: Int] = [:]

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let saves: SaveScheduler
    @ObservationIgnored private var registryCache: [UUID: (revision: [Int], registry: NotationRegistry)] = [:]
    @ObservationIgnored private var macroCache: [UUID: (revision: Int, macros: MacroSet)] = [:]
    /// Called with a problem's stable ID just before it is deleted, so requests still running for it stop
    /// without writing into deleted records.
    @ObservationIgnored var willDelete: ((UUID) -> Void)?

    init(context: ModelContext, saves: SaveScheduler) {
        self.context = context
        self.saves = saves
    }

    // MARK: Problems

    /// A new problem with its main branch and its theorem, created by the person using the app.
    @discardableResult
    func createProblem(title: String = "Untitled problem", statementLaTeX: String = "") -> Problem {
        let problem = Problem(title: title, statementLaTeX: statementLaTeX)
        problem.createdByID = me().stableID
        context.insert(problem)
        let main = Branch(name: "Main line", state: .live)
        problem.branches = [main]
        problem.mainBranchID = main.stableID
        attachTheorem(to: problem)
        saves.markDirty()
        return problem
    }

    /// Changes the title and statement. The statement is the theorem's text, so once a Lean result or fidelity
    /// review was given for that wording it can no longer change (invariant 12); nothing is changed then.
    func update(_ problem: Problem, title: String, statementLaTeX: String) throws(StatementError) {
        guard problem.title != title || problem.statementLaTeX != statementLaTeX else { return }
        if problem.statementLaTeX != statementLaTeX, statementIsLocked(problem) { throw .textLockedByLeanCheck }
        problem.title = title
        problem.statementLaTeX = statementLaTeX
        // The theorem's text is the problem statement, in one direction only.
        if let theorem = pinnedStatement(of: problem), theorem.statementLaTeX != statementLaTeX {
            theorem.statementLaTeX = statementLaTeX
        }
        contextRevisions[problem.stableID, default: 0] += 1
        saves.markDirty()
    }

    func delete(_ problem: Problem) {
        willDelete?(problem.stableID)
        notationRevisions[problem.stableID] = nil
        contextRevisions[problem.stableID] = nil
        registryCache[problem.stableID] = nil
        macroCache[problem.stableID] = nil
        context.delete(problem)
        saves.markDirty()
    }

    func problem(id: UUID?) -> Problem? {
        guard let id else { return nil }
        return context.first(Problem.self, stableID: id)
    }

    /// The most recently created problem, which a new window opens on.
    func mostRecentProblem() -> Problem? {
        var descriptor = FetchDescriptor<Problem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: The problem's theorem

    /// The statement the problem pins: its theorem, if it has one.
    func pinnedStatement(of problem: Problem) -> Statement? {
        guard let id = problem.pinnedStatementID else { return nil }
        return (problem.statements ?? []).first { $0.stableID == id }
    }

    /// Whether the problem statement is fixed: a Lean result or fidelity review was given for its theorem's wording.
    func statementIsLocked(_ problem: Problem) -> Bool {
        pinnedStatement(of: problem)?.hasLeanCheck ?? false
    }

    /// The problem's theorem, created if it has none and brought in line with the problem statement, unless its
    /// wording is fixed by a Lean check.
    @discardableResult
    func ensurePinnedTheorem(for problem: Problem) -> Statement {
        if let theorem = pinnedStatement(of: problem) {
            if theorem.statementLaTeX != problem.statementLaTeX, !theorem.hasLeanCheck {
                theorem.statementLaTeX = problem.statementLaTeX
                saves.markDirty()
            }
            return theorem
        }
        let theorem = attachTheorem(to: problem)
        saves.markDirty()
        return theorem
    }

    /// Gives every problem its theorem. Problems created before Milestone 4 have none.
    func ensurePinnedTheorems() {
        for problem in (try? context.fetch(FetchDescriptor<Problem>())) ?? [] {
            ensurePinnedTheorem(for: problem)
        }
    }

    @discardableResult
    private func attachTheorem(to problem: Problem) -> Statement {
        let existing = (problem.statements ?? []).map(\.label)
        let theorem = Statement(kind: .theorem, label: StatementLabels.next(for: .theorem, existing: existing),
                                statementLaTeX: problem.statementLaTeX, author: .human(me().personID))
        // First in the graph's order.
        theorem.createdAt = problem.createdAt
        problem.statements = (problem.statements ?? []) + [theorem]
        problem.pinnedStatementID = theorem.stableID
        return theorem
    }

    /// Records that what prompts carry changed, so the composer's estimate is rebuilt. The caller marks dirty.
    func contextChanged(of problem: Problem) {
        contextRevisions[problem.stableID, default: 0] += 1
    }

    // MARK: Provider policy and slots

    /// Whether the problem may be sent to a provider (invariant 15).
    func allows(_ providerID: String, for problem: Problem) -> Bool {
        problem.allowedProviderIDs.contains(providerID)
    }

    func setProvider(_ providerID: String, allowed: Bool, for problem: Problem) {
        guard allows(providerID, for: problem) != allowed else { return }
        if allowed {
            problem.allowedProviderIDs.append(providerID)
        } else {
            problem.allowedProviderIDs.removeAll { $0 == providerID }
        }
        saves.markDirty()
    }

    /// A new slot with the next free letter. `stableID` is given when a send already built its requests for the
    /// slot it is about to create.
    @discardableResult
    func addSlot(to problem: Problem, providerID: String, modelID: String, role: SlotRole = .prover,
                 stableID: UUID? = nil) -> ModelSlot {
        let letter = Self.nextLetter(after: problem.sortedModelSlots.map(\.letter))
        let slot = ModelSlot(letter: letter, providerID: providerID, modelID: modelID, role: role)
        if let stableID { slot.stableID = stableID }
        slot.colorTokenRaw = Self.colorToken(forLetter: letter).rawValue
        problem.modelSlots = (problem.modelSlots ?? []) + [slot]
        slotsChanged(problem)
        return slot
    }

    /// Letters are never reused while a slot holds them, so provenance never names two models alike.
    static func nextLetter(after used: [String]) -> String {
        let taken = Set(used)
        return ["A", "B", "C", "D", "E", "F", "G", "H"].first { !taken.contains($0) } ?? "M\(taken.count + 1)"
    }

    func setModel(_ modelID: String, for slot: ModelSlot) {
        guard slot.modelID != modelID else { return }
        slot.modelID = modelID
        if let problem = slot.problem { slotsChanged(problem) } else { saves.markDirty() }
    }

    /// What the slot does from now on. Messages it already wrote keep the role they were written in.
    func setRole(_ role: SlotRole, for slot: ModelSlot) {
        guard slot.role != role else { return }
        slot.role = role
        if let problem = slot.problem { slotsChanged(problem) } else { saves.markDirty() }
    }

    private func slotsChanged(_ problem: Problem) {
        contextRevisions[problem.stableID, default: 0] += 1
        saves.markDirty()
    }

    static func colorToken(forLetter letter: String) -> ColorToken {
        switch letter {
        case "A": .modelA
        case "B": .modelB
        case "C": .modelC
        default: .coauthor
        }
    }

    // MARK: People

    /// The person using this copy of the app ("You"), created on first need. Should an import ever bring a second
    /// "me", the earliest counts, here and everywhere (`Person.me(among:)`).
    func me() -> Person {
        let mine = (try? context.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.isMe }))) ?? []
        if let existing = Person.me(among: mine) { return existing }
        let person = Person(name: "You", initials: "You", isMe: true)
        context.insert(person)
        saves.markDirty()
        return person
    }

    func personIDs() -> Set<UUID> {
        Set(((try? context.fetch(FetchDescriptor<Person>())) ?? []).map(\.stableID))
    }

    // MARK: Notation

    @discardableResult
    func addConvention(to problem: Problem, symbolLaTeX: String, meaning: String, macroDefinition: String?,
                       includeInContext: Bool = true) throws(NotationError) -> NotationEntry {
        let canonical = try Self.canonicalMacro(macroDefinition)
        let entry = NotationEntry(symbolLaTeX: symbolLaTeX, meaning: meaning, macroDefinition: canonical,
                                  includeInContext: includeInContext)
        entry.sortIndex = (problem.notation ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0
        problem.notation = (problem.notation ?? []) + [entry]
        notationChanged(problem)
        return entry
    }

    func updateConvention(_ entry: NotationEntry, symbolLaTeX: String, meaning: String, macroDefinition: String?,
                          includeInContext: Bool) throws(NotationError) {
        let canonical = try Self.canonicalMacro(macroDefinition)
        entry.symbolLaTeX = symbolLaTeX
        entry.meaning = meaning
        entry.macroDefinition = canonical
        entry.includeInContext = includeInContext
        if let problem = entry.problem { notationChanged(problem) }
    }

    func setIncludeInContext(_ entry: NotationEntry, _ include: Bool) {
        guard entry.includeInContext != include else { return }
        entry.includeInContext = include
        // Prompts change; macros, and so rendering, do not.
        if let problem = entry.problem { contextRevisions[problem.stableID, default: 0] += 1 }
        saves.markDirty()
    }

    func deleteConvention(_ entry: NotationEntry) {
        let problem = entry.problem
        // Detach first: until the next save the relationship could still list a deleted entry, and its macro
        // would keep applying.
        problem?.notation?.removeAll { $0 === entry }
        context.delete(entry)
        if let problem { notationChanged(problem) }
    }

    /// Imports every macro definition in `preamble`. A name that already exists is updated (as
    /// `\renewcommand` would); nothing is duplicated; everything not imported is reported.
    @discardableResult
    func importPreamble(_ preamble: String, into problem: Problem) -> PreambleImportReport {
        let parsed = MacroParser.parse(preamble)
        var report = PreambleImportReport(skipped: parsed.skipped)
        var byName: [String: NotationEntry] = [:]
        for entry in problem.notation ?? [] {
            if let source = entry.macroDefinition, let name = MacroParser.parse(source).definitions.first?.name {
                byName[name] = entry
            }
        }
        var nextIndex = (problem.notation ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0
        for definition in parsed.definitions {
            if let existing = byName[definition.name] {
                if existing.macroDefinition != definition.canonicalSource {
                    existing.macroDefinition = definition.canonicalSource
                    report.updated.append(definition.name)
                }
            } else {
                let entry = NotationEntry(symbolLaTeX: Self.sampleUse(of: definition), meaning: "",
                                          macroDefinition: definition.canonicalSource)
                entry.sortIndex = nextIndex
                nextIndex += 1
                problem.notation = (problem.notation ?? []) + [entry]
                byName[definition.name] = entry
                report.added.append(definition.name)
            }
        }
        if !report.added.isEmpty || !report.updated.isEmpty { notationChanged(problem) }
        return report
    }

    /// The notation as values (rows, macros, prompt block), recomputed only when it changes.
    func notation(for problem: Problem) -> NotationRegistry {
        let revision = [notationRevisions[problem.stableID, default: 0], contextRevisions[problem.stableID, default: 0]]
        if let cached = registryCache[problem.stableID], cached.revision == revision { return cached.registry }
        let registry = NotationRegistry(entries: problem.sortedNotation)
        registryCache[problem.stableID] = (revision, registry)
        return registry
    }

    /// Macros and size for rendering this problem's math. Depends on macro changes only.
    func mathContext(for problem: Problem, fontSize: Double = 16) -> MathContext {
        let revision = notationRevisions[problem.stableID, default: 0]
        if let cached = macroCache[problem.stableID], cached.revision == revision {
            return MathContext(macros: cached.macros, fontSize: fontSize)
        }
        let macros = NotationRegistry(entries: problem.sortedNotation).macros
        macroCache[problem.stableID] = (revision, macros)
        return MathContext(macros: macros, fontSize: fontSize)
    }

    private func notationChanged(_ problem: Problem) {
        notationRevisions[problem.stableID, default: 0] += 1
        saves.markDirty()
    }

    /// Accepts empty (no macro) or exactly one definition, and stores its canonical form.
    private static func canonicalMacro(_ source: String?) throws(NotationError) -> String? {
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parsed = MacroParser.parse(source)
        if let skipped = parsed.skipped.first { throw NotationError(message: skipped.reason) }
        guard parsed.definitions.count == 1, let definition = parsed.definitions.first else {
            throw NotationError(message: parsed.definitions.isEmpty
                ? "Write one definition, such as \\newcommand{\\Z}{\\mathbb{Z}}"
                : "Write one definition per convention")
        }
        return definition.canonicalSource
    }

    /// How a macro is shown in the sidebar: `\abs{x}` for one argument, `\Z` for none.
    static func sampleUse(of definition: MacroDefinition) -> String {
        let placeholders = ["x", "y", "z", "u", "v", "w", "a", "b", "c"]
        return "\\" + definition.name + (0..<definition.arity).map { "{\(placeholders[$0])}" }.joined()
    }
}

extension Person {
    /// The person using the app among `people`: the earliest record marked as such, so every reader agrees.
    static func me(among people: [Person]) -> Person? {
        people.filter(\.isMe).min { ($0.createdAt, $0.stableID.uuidString) < ($1.createdAt, $1.stableID.uuidString) }
    }
}
