import Foundation

/// What the verification cards and sheets say. Kept out of the views so the words that state what a check means, and
/// what it does not, are tested.
enum VerificationWording {
    static let formalizeExplanation = "A formalizer drafts the Lean statement and its proof. Nothing is checked until you click Check on the draft, and the statement counts as verified in Lean only when you confirm that the Lean statement says what this one says."

    static let checkExplanation = "Lean compiles the module offline, in a sandbox that can write only to a folder of its own. The app's own check then replays the compiled module through Lean's kernel and reads each statement's axioms; none of the module's code runs in it."

    static let fidelityExplanation = "Confirm only if the Lean statement says exactly what the informal one says: the same hypotheses, nothing weaker and nothing stronger. Lean checks the proof of the Lean statement, not this match."

    static let scoutExplanation = "A scout writes one self-contained computation with its exact scope. It runs only when you click Run on its code, offline and in a sandbox. Whatever it reports is evidence over its scope, never a proof; a counterexample refutes nothing until you accept it."

    static let citationExplanation = "Only the words below are sent, to export.arxiv.org and api.zbmath.org, one citation at a time. A lookup that cannot decide leaves a citation unchecked, never \"not found\"; \"found\" means a document matching it exists, not that it says what the step needs."

    static let exportPlaceholder = "Exporting LaTeX, a Kerodon manuscript, a Lean project and the AI-use statement comes with the next part of this milestone."

    /// "No model is a formalizer…".
    static func noSlot(_ role: SlotRole) -> String {
        let name = role == .formalizer ? "formalizer" : "scout"
        return "No model is a \(name). Choose \(name.capitalized) as a model's role from its chip in the toolbar."
    }

    /// Under code too long for its box: all of it is there to read.
    static func lineCount(_ lines: Int) -> String {
        "\(lines) lines; scroll to read them all."
    }

    /// The module a check runs, beyond the statement's own code.
    static func moduleLine(others: [String]) -> String {
        others.isEmpty ? "The module holds this statement's code only."
            : "The module also holds the checked code of \(Prose.list(others)), so a proof can use them; each is checked again in this run."
    }

    static func refutationConsequence(_ label: String) -> String {
        "Accepting marks \(label) refuted. What uses it is capped and shows that it depends on a refuted claim, and every model is told it is false, in your words. You can withdraw the acceptance later; the run stays recorded."
    }

    /// "sorry at lines 4 and 9".
    static func sorries(_ locations: [LeanLocation]) -> String? {
        guard !locations.isEmpty else { return nil }
        let lines = Array(Set(locations.map(\.line))).sorted().map(String.init)
        return (locations.count == 1 ? "sorry" : "\(locations.count) sorries") + " at line" + (lines.count == 1 ? " " : "s ")
            + Prose.list(lines)
    }

    /// The axioms a check reported, standard or not, in words.
    static func axioms(_ facts: LeanFacts) -> String {
        guard let axioms = facts.axioms else { return "Axioms unknown: the axiom check did not report." }
        if axioms.isEmpty { return "Depends on no axioms." }
        let other = facts.nonstandardAxioms
        let line = "Axioms: " + axioms.joined(separator: ", ") + "."
        return other.isEmpty ? line : line + " Beyond the standard three: " + other.joined(separator: ", ") + "."
    }

    /// What a run's code reported, with its scope: never "passed" or "verified". Typeset (the scope is a person's or a
    /// model's prose); what the program printed is never in it (`reported`).
    static func run(_ fact: EvidenceFact) -> String {
        let scope = fact.scope.isEmpty ? "" : " (scope: \(fact.scope))"
        return switch (fact.outcome, fact.verdict) {
        case (.completed, .holds): "No counterexample found" + scope + "."
        case (.completed, .counterexample): "Its code reported a counterexample" + scope + "."
        case (.completed, .inconclusive): "Inconclusive" + scope + "."
        case (.exitedNonzero, _): "The run failed" + scope + "."
        case (.timedOut, _): "The run ran out of time" + scope + "."
        case (.memoryLimit, _): "The run ran out of memory" + scope + "."
        case (.diskLimit, _): "The run wrote more than its folder may hold" + scope + "."
        case (.stopped, _): "The run was stopped" + scope + "."
        case (.couldNotRun, _): "The run could not start."
        }
    }

    /// What the program printed after its result line, exactly, shown as it was printed and never typeset.
    static func reported(_ fact: EvidenceFact) -> String? {
        fact.detail.isEmpty || fact.outcome != .completed || fact.verdict == .holds ? nil : "Reported: " + fact.detail
    }

    /// Who ran it, when, for how long, and whether its output was cut.
    static func runLine(_ fact: EvidenceFact, authors: AuthorDirectory) -> String {
        "Run by \(authors.name(ofPerson: fact.runByID)) · \(fact.createdAt.formatted(date: .abbreviated, time: .shortened))"
            + " · \(fact.seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
            + (fact.truncated ? " · output cut to fit" : "")
    }

    /// "3 runs; latest: …" in the inspector, or nothing for a single run.
    static func runCount(_ count: Int) -> String {
        count == 1 ? "" : Prose.count(count, "run") + "; latest: "
    }

    /// The run a refutation would rest on; typeset, since the scope may hold mathematics.
    static func refutationRun(tool: EvidenceTool, scope: String) -> String {
        "\(ToolID(tool).displayName) run over \(scope); its code reported a counterexample."
    }

    /// Where a person's review of the Lean statement stands.
    static func fidelity(_ fidelity: FidelityStanding, label: String, authors: AuthorDirectory) -> String {
        switch fidelity {
        case .pending: "No person has confirmed that the Lean statement says what \(label) says."
        case .confirmed(let person): "Confirmed by \(authors.name(ofPerson: person))."
        case .differs(let person): "\(authors.name(ofPerson: person)) found that it says something else."
        case .outdated: "Confirmed for an earlier version of the Lean or the informal statement."
        }
    }

    /// When and with what a statement's code was checked, and who wrote the code.
    static func checked(_ facts: LeanFacts, authors: AuthorDirectory) -> String? {
        facts.checkedAt.map {
            "Checked \($0.formatted(date: .abbreviated, time: .shortened)) with Lean \(facts.leanVersion), Mathlib \(facts.mathlibRev); code by \(authors.name(of: facts.sourceAuthor))."
        }
    }

    /// What a citation's last lookup found, beyond its status: the matching document, or why it could not decide.
    static func lookup(_ fact: CitationFact) -> String? {
        switch fact.status {
        case .found: fact.matchedTitle.map { "Matches \u{201C}\($0)\u{201D} in \(fact.indexName ?? "an index")." }
        case .unverified: fact.detail.map { "Last lookup could not decide: \($0)." }
        case .notFound: nil
        }
    }

    /// Exactly what a citation's lookup sends, or that it sends nothing (invariant 6).
    static func sends(_ citation: String) -> String {
        CitationRules.canLookUp(citation) ? "Sends: " + CitationRules.query(citation) : "Too little to look up; nothing is sent."
    }

    /// Why asking a formalizer or a scout waits (invariant 9): its sheet names the models.
    static let waitsWhileBlind = "Asking a formalizer or a scout shows which models there are, so it waits while blind mode is on in Compare. Turn blind mode off to ask."

    /// Under the inspector's actions.
    static let inspectorCaption = "Review Steps opens the source steps; checking happens there. No button sets a status: Lean and computations run only when you click Check or Run on what will run."
}
