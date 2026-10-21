import SwiftUI

/// Where a scout's request starts: the claim to test and the statements its evidence may be attached to (the first is
/// proposed). The request is derived from the attempts the chosen statement came from (`ScoutBasis.make`).
nonisolated struct ScoutSeed: Hashable, Sendable {
    var claim: String
    var statements: [UUID]
    /// From a row of a comparison, named only "Attempt 1" and "Attempt 2".
    var fromCompare = false
}

/// What a screen asks of verification, through the window's `verificationActions`, by stable ID only, so the handler
/// reads nothing from the render that made it. Sheets open in `VerificationSheetHost`; the rest acts at once.
nonisolated enum VerificationIntent: Hashable, Sendable {
    case formalize(statement: UUID)
    /// Opens the check sheet on a candidate: a draft, the checked code, or code to edit from either.
    case checkLean(statement: UUID, candidate: LeanCandidate, editing: Bool)
    case confirmStatement(UUID)
    case withdrawFidelity(statement: UUID)
    case stopLean(problem: UUID)
    case askForCheck(ScoutSeed)
    case writeCell(statement: UUID, basedOn: UUID?)
    /// Runs a cell's code; `shown` is the digest of the code the button was shown beside.
    case runCell(messageID: UUID, shown: TextDigest)
    case stopCell(UUID)
    case acceptRefutation(statement: UUID, evidence: UUID)
    case withdrawRefutation(statement: UUID)
    case checkCitations(attempt: UUID)
    case stopCitations
    case addCitation(step: UUID)
    case removeCitation(UUID)

    /// Opens a sheet that names models (slot pickers, estimates): it waits while blind mode hides them (invariant 9).
    var waitsWhileBlind: Bool {
        switch self {
        case .formalize, .askForCheck: true
        default: false
        }
    }
}

/// A verification sheet, open in one window.
nonisolated enum VerificationSheet: Hashable, Sendable, Identifiable {
    case formalize(statement: UUID)
    case leanCheck(statement: UUID, candidate: LeanCandidate, editing: Bool)
    case fidelity(statement: UUID)
    case scout(ScoutSeed)
    case cellEditor(statement: UUID, basedOn: UUID?)
    case refutation(statement: UUID, evidence: UUID)
    case citationCheck(attempt: UUID)
    case citationAdd(step: UUID)

    var id: Self { self }

    var waitsWhileBlind: Bool {
        switch self {
        case .formalize, .scout: true
        default: false
        }
    }
}

/// The window's handler of verification intents.
typealias VerificationActions = PresentedAction<VerificationIntent>

/// The services the handler acts through, read from the environment when the host is drawn.
struct VerificationServices {
    var lean: LeanService?
    var compute: ComputeService?
    var citations: CitationService?
    var graph: StatementGraph?
    var problems: ProblemManager?
}

/// The one handler of verification intents. Sheets open in the window; the rest acts at once, and a refusal is said
/// aloud and shown in the window's notice.
enum VerificationIntentHandler {
    static func perform(_ intent: VerificationIntent, window: WindowState, services: VerificationServices) {
        if intent.waitsWhileBlind, window.hidesModelChrome {
            return refuse(VerificationWording.waitsWhileBlind, window: window)
        }
        switch intent {
        case .formalize(let statement):
            window.verificationSheet = .formalize(statement: statement)
        case .checkLean(let statement, let candidate, let editing):
            window.verificationSheet = .leanCheck(statement: statement, candidate: candidate, editing: editing)
        case .confirmStatement(let statement):
            window.verificationSheet = .fidelity(statement: statement)
        case .withdrawFidelity(let statement):
            act(window: window) { () throws(VerificationError) in
                try services.lean?.withdrawFidelity(statement: statement)
                VoiceOver.announce("Review of the Lean statement withdrawn")
            }
        case .stopLean(let problem):
            services.lean?.stopCheck(problem: problem)
        case .askForCheck(let seed):
            window.verificationSheet = .scout(seed)
        case .writeCell(let statement, let basedOn):
            window.verificationSheet = .cellEditor(statement: statement, basedOn: basedOn)
        case .runCell(let messageID, let shown):
            act(window: window) { () throws(VerificationError) in try services.compute?.run(cell: messageID, shown: shown) }
        case .stopCell(let cell):
            services.compute?.stop(cell: cell)
        case .acceptRefutation(let statement, let evidence):
            window.verificationSheet = .refutation(statement: statement, evidence: evidence)
        case .withdrawRefutation(let statementID):
            guard let problemID = window.selectedProblemID, let problem = services.problems?.problem(id: problemID) else {
                return
            }
            act(window: window) { () throws(VerificationError) in
                try services.graph?.withdrawRefutation(statementID, in: problem)
                VoiceOver.announce("Refutation withdrawn")
            }
        case .checkCitations(let attempt):
            window.verificationSheet = .citationCheck(attempt: attempt)
        case .stopCitations:
            services.citations?.stop()
        case .addCitation(let step):
            window.verificationSheet = .citationAdd(step: step)
        case .removeCitation(let citation):
            act(window: window) { () throws(VerificationError) in
                try services.citations?.remove(citation)
                VoiceOver.announce("Citation removed")
            }
        }
    }

    private static func act(window: WindowState, _ body: () throws(VerificationError) -> Void) {
        do throws(VerificationError) {
            try body()
            window.verificationNotice = nil
        } catch {
            refuse(error.message, window: window)
        }
    }

    private static func refuse(_ message: String, window: WindowState) {
        window.verificationNotice = message
        VoiceOver.announce(message)
    }
}

extension EnvironmentValues {
    /// The window's handler of verification intents (`VerificationSheetHost`). Unset where nothing can be verified.
    @Entry var verificationActions: VerificationActions? = nil
}
