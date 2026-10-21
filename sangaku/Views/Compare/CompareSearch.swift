import Foundation

/// Where a counterexample search from a Compare row starts: the row's claims, and the statements its evidence may be
/// attached to: those resting on the row's steps first, the narrowest (fewest source steps) leading, then the theorem,
/// then the rest.
enum CompareSearch {
    static func seed(_ row: CompareRow, problem: Problem) -> ScoutSeed {
        let steps = Set([row.a?.id, row.b?.id].compactMap { $0 })
        let statements = (problem.statements ?? []).sorted { ($0.createdAt, $0.stableID.uuidString) < ($1.createdAt, $1.stableID.uuidString) }
        let resting = statements.filter { ($0.sourceSteps ?? []).contains { steps.contains($0.stableID) } }
            .sorted { ($0.sourceSteps ?? []).count < ($1.sourceSteps ?? []).count }
        let theorem = statements.filter { $0.stableID == problem.pinnedStatementID }
        var ordered: [UUID] = []
        for statement in resting + theorem + statements where !ordered.contains(statement.stableID) {
            ordered.append(statement.stableID)
        }
        return ScoutSeed(claim: CompareWording.scoutClaim(row), statements: ordered, fromCompare: true)
    }
}
