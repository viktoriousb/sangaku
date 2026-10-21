import Foundation

/// The Lean installation a check ran with, recorded on every result: a Mathlib name can change meaning between
/// versions, so a result says which one it was checked against.
nonisolated struct LeanEnvironment: Hashable, Codable, Sendable {
    /// The elan toolchain, e.g. `leanprover/lean4:v4.33.1`.
    var toolchain: String
    var leanVersion: String
    var mathlibRev: String
}

extension LeanResult {
    /// Records one statement's part of a check, replacing every field together so nothing is mixed between two runs.
    /// The only writer of `axiomCheckedDeclaration` and `checkedDigest` outside the fixture (invariant 12): the axiom
    /// fields can only come from the service's own reading (`LeanRegionOutcome`). `checkedAt` is written last.
    func record(_ outcome: LeanRegionOutcome, module: TextDigest, environment: LeanEnvironment, checkedBy: UUID?,
                sourceAuthor: Author?, draftMessageID: UUID?, duration: Double, at date: Date) {
        source = outcome.source.text
        leanStatementSource = outcome.source.statementPart
        messages = outcome.messages
        sorryCount = outcome.sorryCount
        sorryLocations = outcome.sorryLocations
        switch outcome.axiomCheck {
        case .ran(let declaration, let axioms):
            self.axioms = axioms
            axiomCheckedDeclaration = declaration
        case .notRun:
            axioms = []
            axiomCheckedDeclaration = ""
        }
        checkedDigest = TextDigest(of: source).hex
        moduleDigest = module.hex
        toolchain = environment.toolchain
        leanVersion = environment.leanVersion
        mathlibRev = environment.mathlibRev
        durationSeconds = duration
        checkedByID = checkedBy
        self.sourceAuthor = sourceAuthor
        self.draftMessageID = draftMessageID
        checkedAt = date
    }
}
