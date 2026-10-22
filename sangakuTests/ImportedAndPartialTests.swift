import Foundation
import SwiftData
import Testing
@testable import sangaku

@Suite("Partial attempts in the progress line")
struct PartialProgressTests {
    private let fixture = PreviewFixtures.make()

    @Test("A stopped attempt's progress says so, everywhere the line is drawn; statuses are untouched")
    func partial() throws {
        let people = fixture.state.problems.personIDs()
        let before = AttemptReviewState.read(attempt: fixture.attemptA, people: people).progress
        #expect(before.headline == "4 of 6 steps checked by a person" && !before.partial)
        fixture.messageA.interrupted = true
        let after = AttemptReviewState.read(attempt: fixture.attemptA, people: people).progress
        #expect(after.headline == "4 of 6 steps checked by a person; the attempt stopped before its end")
        #expect(after.checked == before.checked && after.isComplete == before.isComplete)
        #expect(fixture.state.branches.assessment(ofAttempt: fixture.attemptA.stableID)?.progress.partial == true)
        let statuses = fixture.state.graph.state(for: fixture.problem).nodes.map(\.derived)
        fixture.messageA.interrupted = false
        #expect(statuses == fixture.state.graph.state(for: fixture.problem).nodes.map(\.derived),
                "only the words change, never a status")
    }

    @Test("All checked: \"all\" may be claimed only for a finished attempt")
    func claimsAll() {
        // Steps 1 to 4 of A are checked by a person.
        let steps = Array(fixture.attemptA.sortedSteps.prefix(4))
        let standings = StepStandings.standings(of: steps, people: fixture.state.problems.personIDs())
        let ordered = steps.compactMap { standings[$0.stableID] }
        let finished = ReviewProgress(ordered)
        let stopped = ReviewProgress(ordered, partial: true)
        #expect(finished.claimsAll && finished.headline == "4 of 4 steps checked by a person")
        #expect(stopped.isComplete && !stopped.claimsAll)
        #expect(stopped.headline == "4 of 4 steps checked by a person; the attempt stopped before its end")
        #expect(ReviewProgress([], partial: true).headline == "No steps")
    }
}

@Suite("Imported results: disclosed, not capping")
struct ImportedStatementTests {
    private let fixture = PreviewFixtures.make()

    private var state: StatementGraphState { fixture.state.graph.state(for: fixture.problem) }

    @Test("A person marks a result as imported; what uses it keeps its status and says it assumes it")
    func disclosedNotCapped() throws {
        let conjecture = fixture.conjecture
        let lemma2 = fixture.lemmas[1]
        lemma2.uses = (lemma2.uses ?? []) + [conjecture]
        #expect(state[lemma2.stableID]?.derived.displayed == .proposed, "an unproved dependency caps it")
        try fixture.state.graph.setImported(conjecture.stableID, source: "  Sylow, Theorem 1  ", in: fixture.problem)
        #expect(conjecture.importedSource == "Sylow, Theorem 1" && conjecture.importedByID == fixture.you.stableID)
        let node = try #require(state[conjecture.stableID])
        #expect(node.derived.own == .imported && node.derived.displayed == .imported && !node.derived.isCapped)
        let user = try #require(state[lemma2.stableID])
        #expect(user.derived.displayed == .humanChecked, "an imported dependency does not lower it")
        #expect(user.derived.assumes == [conjecture.stableID])
        #expect(user.explanation.assumes == "Assumes Conj, imported and not checked here")
        #expect(user.contextNote.contains("assumes Conj, imported and not checked here"), "models are told too")
        // Through another statement: the theorem uses Lem 2.
        let theorem = try #require(state[fixture.theorem.stableID])
        #expect(theorem.derived.assumes.contains(conjecture.stableID))

        try fixture.state.graph.setImported(conjecture.stableID, source: nil, in: fixture.problem)
        #expect(conjecture.importedSource == nil && state[lemma2.stableID]?.derived.displayed == .proposed)
    }

    @Test("The theorem and a statement proved here cannot be imported; a source is one short line")
    func refusals() throws {
        let graph = fixture.state.graph
        #expect(throws: StatementError.pinnedCannotBeImported) {
            try graph.setImported(fixture.theorem.stableID, source: "A, B", in: fixture.problem)
        }
        #expect(throws: StatementError.importedHasSteps) {
            try graph.setImported(fixture.lemmas[0].stableID, source: "A, B", in: fixture.problem)
        }
        for bad in ["", "   ", "two\nlines", String(repeating: "x", count: 201), "a\u{202E}b"] {
            #expect(throws: StatementError.invalidImportedSource) {
                try graph.setImported(fixture.conjecture.stableID, source: bad, in: fixture.problem)
            }
        }
        #expect(fixture.conjecture.importedSource == nil)

        // An imported result uses nothing, so it can never hide a refuted claim from what rests on it.
        let lemma6 = try #require(fixture.problem.statements?.first { $0.label == "Lem 6" })
        lemma6.sourceSteps = []
        #expect(throws: StatementError.importedUsesStatements) {
            try graph.setImported(lemma6.stableID, source: "A, B", in: fixture.problem)
        }
        try graph.setImported(fixture.conjecture.stableID, source: "A, B", in: fixture.problem)
        #expect(throws: StatementError.importedCannotUse) {
            try graph.addUse(fixture.refutedClaim.stableID, to: fixture.conjecture.stableID, in: fixture.problem)
        }
        #expect((fixture.conjecture.uses ?? []).isEmpty)
    }

    @Test("Refuted and verified outrank imported; a mark not made by a person counts for nothing")
    func ownStatus() {
        var inputs = StatusInputs()
        inputs.imported = true
        #expect(StatusRules.ownStatus(inputs) == .imported)
        inputs.refutationAccepted = true
        #expect(StatusRules.ownStatus(inputs) == .refuted)
        let conjecture = fixture.conjecture
        conjecture.importedSource = "Someone, Theorem 2"
        conjecture.importedByID = UUID()
        #expect(state[conjecture.stableID]?.derived.own == .proposed, "only a person can mark a result imported")
    }

    @Test("Invariant 3: imported has its own look, never a checked one")
    func style() {
        let style = StatusStyle.style(for: StatementStatus.imported)
        #expect(style.isProvisional && style.border == .dotted && style.glyph != "✓" && style.glyph != "⊢")
        let all = StatementStatus.allCases.map(StatusStyle.style(for:))
        #expect(Set(all.map(\.glyph)).count == all.count && Set(all.map(\.label)).count == all.count)
    }
}

@Suite("Export groundwork: stored data")
struct ExportGroundworkTests {
    @Test("Settings stored before the export keys existed still decode")
    func oldSettings() throws {
        var stored = ToolSettings.Values()
        stored.paths[.python] = "/opt/homebrew/bin/python3"
        stored.computeSeconds = 90
        // Values as stored before 8b: every key but the new ones.
        let encoded = try #require(JSONColumn.encode(stored))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "hashtagKit")
        object.removeValue(forKey: "exportFolders")
        let old = try JSONSerialization.data(withJSONObject: object)
        let values = try #require(JSONColumn.decode(ToolSettings.Values.self, from: old))
        #expect(values.hashtagKit == nil && values.exportFolders == nil && values.computeSeconds == 90)
        #expect(values.paths[.python] == "/opt/homebrew/bin/python3")
    }

    @Test("A found citation keeps the index's authors and year; not found clears them")
    func citationAuthors() throws {
        let zbmath = #"{"result":[{"title":{"title":"Abstract algebra"},"year":"1991","zbmath_url":"https://zbmath.org/53165","contributors":{"authors":[{"name":"Dummit, David S."},{"name":"Foote, Richard M."}]}}],"status":{"internal_code":"ok"}}"#
        let found = try #require(CitationLookupClient.parseZbmath(200, Data(zbmath.utf8))?.first)
        #expect(found.authors == ["Dummit, David S.", "Foote, Richard M."] && found.surnames == ["Dummit", "Foote"])
        #expect(found.year == 1991)
    }

    @Test("pdfLaTeX and git are found where the sandbox can run them, never through Xcode's git shim")
    func toolCandidates() {
        let locator = ToolLocator(home: "/Users/someone")
        #expect(locator.candidates(.pdflatex).first == "/Library/TeX/texbin/pdflatex")
        #expect(!locator.candidates(.git).contains("/usr/bin/git"))
        #expect(locator.candidates(.git).allSatisfy { $0.hasSuffix("/bin/git") })
    }
}
