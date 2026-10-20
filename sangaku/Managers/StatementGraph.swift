import Foundation
import SwiftData

/// The lemmas and claims of each problem and what they use. The only writer of promoted statements and of `uses`
/// edges, and every write is a person's action: nothing a model sends creates or changes a statement
/// (invariant 1). Statuses are derived on every read (`StatementGraphState.read`), never stored or cached, so a
/// verdict or review written elsewhere shows at the next read.
@Observable
final class StatementGraph {
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let saves: SaveScheduler
    @ObservationIgnored let problems: ProblemManager

    init(context: ModelContext, saves: SaveScheduler, problems: ProblemManager) {
        self.context = context
        self.saves = saves
        self.problems = problems
    }

    /// The problem's statements with their derived statuses. Views pass the people they already observe.
    func state(for problem: Problem, people: Set<UUID>? = nil) -> StatementGraphState {
        StatementGraphState.read(problem: problem, people: people ?? problems.personIDs())
    }

    // MARK: Promotion

    /// Makes a lemma or claim of a run of steps, as the person using the app. Everything is checked before
    /// anything is written, so a refusal changes nothing.
    @discardableResult
    func promote(_ draft: PromotionDraft, in problem: Problem) throws(StatementError) -> Statement {
        let state = state(for: problem)
        let label = try validLabel(draft.label, among: state.nodes.map(\.label))
        let text = draft.statementLaTeX.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .emptyStatement }
        guard draft.kind == .lemma || draft.kind == .claim else { throw .kindNotPromotable(draft.kind) }

        guard let attempt = attempt(draft.attemptID) else { throw .noSuchSteps }
        guard attempt.message?.branch?.problem?.stableID == problem.stableID else { throw .notInThisProblem }
        let steps = attempt.sortedSteps.filter { draft.run.contains($0.index) }
        guard steps.count == draft.run.count else { throw .noSuchSteps }

        let statements = problem.statements ?? []
        let used = statements.filter { draft.uses.contains($0.stableID) }
        guard used.count == draft.uses.count else { throw .notInThisProblem }
        let pinned = draft.usedByPinned ? problems.pinnedStatement(of: problem) : nil
        // The new statement is used by nothing else, so the only cycle it can close runs through the theorem.
        if let pinned {
            for statement in used {
                if let path = state.usesGraph.cyclePath(adding: pinned.stableID, uses: statement.stableID) {
                    let labels = path.map(state.label(of:))
                    throw .cycle(labels: [labels[0], label] + labels.dropFirst())
                }
            }
        }

        let statement = Statement(kind: draft.kind, label: label, statementLaTeX: text,
                                  author: .human(problems.me().personID))
        context.insert(statement)
        problem.statements = statements + [statement]
        statement.sourceSteps = steps
        statement.uses = used
        if let pinned { pinned.uses = (pinned.uses ?? []) + [statement] }
        changed(problem)
        return statement
    }

    // MARK: The theorem's proof

    /// Makes an attempt's steps the pinned theorem's proof, as the person using the app (`BranchManager.adopt`). Only
    /// the theorem's source steps change: not its wording, its uses, its reviews or its Lean results. Its status then
    /// derives from those steps like any statement's, so adopting checks nothing (invariants 1 and 13).
    func adoptProof(attemptID: UUID, in problem: Problem) throws(StatementError) {
        guard let attempt = attempt(attemptID) else { throw .noSuchSteps }
        guard attempt.message?.branch?.problem?.stableID == problem.stableID else { throw .notInThisProblem }
        let steps = attempt.sortedSteps
        guard !steps.isEmpty else { throw .noSuchSteps }
        let theorem = problems.ensurePinnedTheorem(for: problem)
        theorem.sourceSteps = steps
        changed(problem)
    }

    // MARK: Dependencies

    /// "`user` uses `dependency`". Refused if it would close a cycle; nothing happens if the edge exists.
    func addUse(_ dependency: UUID, to user: UUID, in problem: Problem) throws(StatementError) {
        guard let userStatement = statement(user, in: problem),
              let dependencyStatement = statement(dependency, in: problem) else { throw .noSuchStatement }
        guard !(userStatement.uses ?? []).contains(where: { $0.stableID == dependency }) else { return }
        let state = state(for: problem)
        if let path = state.usesGraph.cyclePath(adding: user, uses: dependency) {
            throw .cycle(labels: path.map(state.label(of:)))
        }
        userStatement.uses = (userStatement.uses ?? []) + [dependencyStatement]
        changed(problem)
    }

    func removeUse(_ dependency: UUID, from user: UUID, in problem: Problem) {
        guard let userStatement = statement(user, in: problem),
              (userStatement.uses ?? []).contains(where: { $0.stableID == dependency }) else { return }
        userStatement.uses = (userStatement.uses ?? []).filter { $0.stableID != dependency }
        changed(problem)
    }

    // MARK: Editing and deleting

    /// Changes a statement's label and text. The theorem's text is the problem statement, and a wording a Lean
    /// result or fidelity review was given for is fixed.
    func edit(_ id: UUID, label: String, statementLaTeX: String, in problem: Problem) throws(StatementError) {
        guard let statement = statement(id, in: problem) else { throw .noSuchStatement }
        let state = state(for: problem)
        let label = try validLabel(label, among: state.nodes.filter { $0.id != id }.map(\.label))
        let text = statementLaTeX.trimmingCharacters(in: .whitespacesAndNewlines)
        // Compared trimmed: the theorem keeps the problem statement as typed, surrounding whitespace included.
        let textChanged = text != statement.statementLaTeX.trimmingCharacters(in: .whitespacesAndNewlines)
        if textChanged {
            if state[id]?.isPinned == true { throw .pinnedTextIsTheProblemStatement }
            if statement.hasLeanCheck { throw .textLockedByLeanCheck }
            guard !text.isEmpty else { throw .emptyStatement }
        }
        guard label != statement.label || textChanged else { return }
        statement.label = label
        if textChanged { statement.statementLaTeX = text }
        changed(problem)
    }

    /// Deletes a statement. What used it stays, without the edge, so its status may rise: the confirmation names
    /// those statements. The theorem goes only with its problem.
    func delete(_ id: UUID, in problem: Problem) throws(StatementError) {
        guard let statement = statement(id, in: problem) else { throw .noSuchStatement }
        guard problem.pinnedStatementID != id else { throw .pinnedTheoremCannotBeDeleted }
        // Detach first: until the next save a relationship could still list a deleted statement.
        for user in problem.statements ?? [] where (user.uses ?? []).contains(where: { $0 === statement }) {
            user.uses = (user.uses ?? []).filter { $0 !== statement }
        }
        statement.uses = []
        for step in statement.sourceSteps ?? [] {
            step.statements = (step.statements ?? []).filter { $0 !== statement }
        }
        statement.sourceSteps = []
        problem.statements = (problem.statements ?? []).filter { $0 !== statement }
        context.delete(statement)
        changed(problem)
    }

    // MARK: Helpers

    private func changed(_ problem: Problem) {
        problems.contextChanged(of: problem)
        saves.markDirty()
    }

    private func statement(_ id: UUID, in problem: Problem) -> Statement? {
        (problem.statements ?? []).first { $0.stableID == id }
    }

    private func attempt(_ id: UUID) -> ProofAttempt? {
        context.first(ProofAttempt.self, stableID: id)
    }

    private func validLabel(_ label: String, among others: [String]) throws(StatementError) -> String {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw .emptyLabel }
        guard !StatementLabels.isTaken(label, among: others) else { throw .duplicateLabel(label) }
        return label
    }
}
