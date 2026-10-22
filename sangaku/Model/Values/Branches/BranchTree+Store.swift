import Foundation

extension BranchTree {
    /// The tree of a problem as the store has it. `running`: branches with a request running; `live`: messages still
    /// being written (an attempt is shown once it has ended). Each attempt is judged as a statement resting on its
    /// steps would be, so nothing in the tree looks more checked than its steps are (invariant 3).
    static func read(problem: Problem, graph: StatementGraphState, people: Set<UUID>, authors: AuthorDirectory,
                     running: Set<UUID>, live: Set<UUID>, showsDeadEnds: Bool, hidesAuthors: Bool = false) -> BranchTree {
        var branches: [BranchFacts] = []
        var attempts: [AttemptFacts] = []
        for branch in problem.sortedBranches {
            let own = branch.sortedMessages
            var names: [String] = []
            for message in own {
                let name = authors.name(of: message.author)
                if !names.contains(name) { names.append(name) }
            }
            let fork = branch.forkedFrom
            branches.append(BranchFacts(
                id: branch.stableID, createdAt: branch.createdAt, name: branch.name, state: branch.state,
                isMain: branch.stableID == problem.mainBranchID, isRunning: running.contains(branch.stableID),
                forkOwnerID: fork?.branch?.stableID, forkAttemptID: fork?.proofAttempt?.stableID,
                ownMessages: own.count, inheritedMessages: branch.forkedFrom == nil ? 0 : branch.visibleHistory.inherited.count,
                authors: names, firstMessageAt: own.first?.createdAt, lastMessageAt: own.last?.createdAt,
                inContext: branch.state == .deadEnd && branch.includeReasonInContext,
                offers: BranchOffers(branch, mainBranchID: problem.mainBranchID, streaming: running, live: live,
                                     hidesAuthors: hidesAuthors)))
            for message in own where !live.contains(message.stableID) {
                guard let attempt = message.proofAttempt, !(attempt.steps ?? []).isEmpty else { continue }
                let steps = attempt.sortedSteps
                let standings = StepStandings.standings(of: steps, people: people)
                let ordered = steps.compactMap { standings[$0.stableID] }
                let standing = attempt.standingVerdict
                let partial = message.outcome(isStreaming: false).isPartial
                attempts.append(AttemptFacts(
                    id: attempt.stableID, branchID: branch.stableID, createdAt: message.createdAt,
                    author: authors.name(of: message.author), steps: steps.count, isPartial: partial,
                    status: StatusRules.ownStatus(StatusInputs.make(steps: steps, standings: standings)),
                    verdict: standing?.outcome, gapSteps: standing?.outcome == .gap ? standing?.gapStepIndices ?? [] : [],
                    isAdopted: problem.adoptedAttemptID == attempt.stableID, progress: ReviewProgress(ordered, partial: partial),
                    warnings: AdoptionWarning.warnings(standings: ordered, partial: partial)))
            }
        }
        // Lemmas promoted from an attempt other than the adopted proof were salvaged from it; the proof's own lemmas
        // are the main line's, shown in the proof-structure inspector.
        let lemmas: [LemmaFacts] = graph.nodes.compactMap { node in
            guard !node.isPinned, node.kind != .theorem, let attempt = node.sources.first?.attemptID,
                  attempt != problem.adoptedAttemptID else { return nil }
            return LemmaFacts(id: node.id, createdAt: node.createdAt, label: node.label,
                              statementLaTeX: node.statementLaTeX, status: node.derived.displayed, attemptID: attempt)
        }
        return make(problemID: problem.stableID, title: problem.title, theorem: graph.pinned?.label,
                    theoremStatus: graph.pinned?.derived.displayed, branches: branches, attempts: attempts,
                    lemmas: lemmas, showsDeadEnds: showsDeadEnds)
    }
}
