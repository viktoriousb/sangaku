import Foundation
import SwiftData

/// A citation as the person was shown it when they asked for it to be checked.
nonisolated struct ShownCitation: Hashable, Sendable {
    var id: UUID
    var text: String
}

/// Citations on steps: a person adds or removes them, and looks them up on a click (invariant 6). The only writer of
/// citations besides the attempts models write. A lookup sends only each citation's query to arXiv and zbMATH Open;
/// one that cannot decide leaves the citation unverified, never "not found".
@Observable
final class CitationService {
    /// The citations being looked up now.
    private(set) var checking: Set<UUID> = []

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let saves: SaveScheduler
    @ObservationIgnored let problems: ProblemManager
    @ObservationIgnored let client: CitationLookupClient
    /// arXiv asks for a pause between requests.
    @ObservationIgnored private let pause: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Which check is current, so a stopped one ending late cannot clear a newer one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let now: () -> Date
    /// Says when lookups end, for VoiceOver: they end long after the click.
    @ObservationIgnored private let announce: (String) -> Void

    init(context: ModelContext, saves: SaveScheduler, problems: ProblemManager, client: CitationLookupClient,
         pause: Duration = .seconds(3), now: @escaping () -> Date = { .now }, announce: @escaping (String) -> Void = { _ in }) {
        self.context = context
        self.saves = saves
        self.problems = problems
        self.client = client
        self.pause = pause
        self.now = now
        self.announce = announce
    }

    isolated deinit {
        task?.cancel()
    }

    /// A person's citation on a step, unverified until checked.
    @discardableResult
    func add(_ text: String, to stepID: UUID) throws(VerificationError) -> UUID {
        guard let step = context.first(Step.self, stableID: stepID) else { throw .invalid("That step is no longer there.") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300, AttemptParser.clean(text) != nil else {
            throw .invalid("A citation is one line of at most 300 characters.")
        }
        guard !(step.citations ?? []).contains(where: { $0.removedAt == nil && $0.rawText == text }) else {
            throw .invalid("The step already cites that.")
        }
        let citation = Citation(rawText: text, status: .unverified, author: .human(problems.me().personID))
        citation.createdAt = Timestamps.after((step.citations ?? []).map(\.createdAt).max(), now: now())
        context.insert(citation)
        step.citations = (step.citations ?? []) + [citation]
        saves.markDirty()
        return citation.stableID
    }

    /// Removes a citation from view, keeping it for provenance.
    func remove(_ citationID: UUID) throws(VerificationError) {
        guard let citation = context.first(Citation.self, stableID: citationID), citation.removedAt == nil else {
            throw .noSuchCitation
        }
        citation.removedAt = now()
        citation.removedByID = problems.me().stableID
        saves.markDirty()
    }

    /// Looks up the citations the person was shown, one after the other. Refused if any text changed since.
    func check(_ shown: [ShownCitation]) throws(VerificationError) {
        guard task == nil else { throw .lookupRunning }
        guard !shown.isEmpty else { throw .nothingToCheck }
        for item in shown {
            guard let citation = context.first(Citation.self, stableID: item.id), citation.removedAt == nil else {
                throw .noSuchCitation
            }
            guard citation.rawText == item.text else { throw .changedSinceShown }
        }
        let person = problems.me().stableID
        checking = Set(shown.map(\.id))
        generation += 1
        let current = generation
        task = Task { [weak self, client, pause] in
            for (offset, item) in shown.enumerated() {
                if offset > 0 { try? await Task.sleep(for: pause) }
                guard !Task.isCancelled else { break }
                let verdict: CitationVerdict = CitationRules.canLookUp(item.text)
                    ? CitationRules.verdict(item.text, answers: await client.lookUp(item.text, pause: pause))
                    : .unverified("too little to look up")
                // A lookup stopped half way says nothing about the citation.
                guard !Task.isCancelled else { break }
                self?.record(verdict, for: item, by: person)
            }
            if !Task.isCancelled { self?.announce("The citations are looked up.") }
            self?.finishChecking(current)
        }
    }

    func stop() {
        task?.cancel()
        finishChecking(generation)
    }

    private func finishChecking(_ check: Int) {
        guard check == generation else { return }
        task = nil
        checking = []
    }

    /// Records a lookup. One that could not decide leaves a citation an earlier lookup decided as it was.
    private func record(_ verdict: CitationVerdict, for item: ShownCitation, by person: UUID) {
        checking.remove(item.id)
        guard let citation = context.first(Citation.self, stableID: item.id), citation.rawText == item.text else { return }
        if case .unverified = verdict, citation.status != .unverified { return }
        citation.lastQuery = CitationRules.query(item.text)
        citation.checkedAt = now()
        citation.checkedByID = person
        switch verdict {
        case .found(let candidate):
            citation.status = .found
            citation.indexName = candidate.index
            citation.matchedTitle = candidate.title
            citation.resolvedURL = CitationRules.link(status: .found, url: candidate.url)?.absoluteString
            citation.lookupDetail = nil
        case .notFound:
            citation.status = .notFound
            citation.indexName = CitationRules.indexes.joined(separator: " and ")
            citation.matchedTitle = nil
            citation.resolvedURL = nil
            citation.lookupDetail = nil
        case .unverified(let reason):
            citation.status = .unverified
            citation.lookupDetail = reason
        }
        saves.markDirty()
    }
}
