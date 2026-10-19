import Foundation

/// A referee's output (`OutputFormat.refereeVerdicts`), read but not yet trusted: `VerdictMapper` decides what it
/// may say about each attempt.
nonisolated struct RefereeReport: Hashable, Sendable {
    nonisolated struct Entry: Hashable, Sendable {
        var attempt: String
        var outcome: String
        var gapSteps: [Int]
        var rationale: String
    }

    var verdicts: [Entry]
    var summary: String
}

/// Reads a referee's output whole, or not at all: a referee that stopped early gives no verdicts.
nonisolated enum RefereeParser {
    private struct EntryDTO: Decodable {
        let attempt: String
        let outcome: String
        let gapSteps: [Int]
        let rationale: String

        enum CodingKeys: String, CodingKey {
            case attempt, outcome, rationale
            case gapSteps = "gap_steps"
        }
    }

    private struct ReportDTO: Decodable {
        let verdicts: [EntryDTO]
        let summary: String
    }

    static func parse(_ text: String) -> RefereeReport? {
        guard let dto = try? JSONDecoder().decode(ReportDTO.self, from: Data(text.utf8)),
              let summary = AttemptParser.clean(dto.summary) else { return nil }
        var entries: [RefereeReport.Entry] = []
        for entry in dto.verdicts {
            guard let attempt = AttemptParser.clean(entry.attempt), let rationale = AttemptParser.clean(entry.rationale),
                  let outcome = AttemptParser.clean(entry.outcome) else { return nil }
            entries.append(RefereeReport.Entry(attempt: attempt, outcome: outcome, gapSteps: entry.gapSteps,
                                               rationale: rationale))
        }
        return RefereeReport(verdicts: entries, summary: summary)
    }
}

/// An attempt as the referee was shown it.
nonisolated struct AttemptRef: Hashable, Sendable {
    var messageID: UUID
    var letter: String
    /// Steps the attempt was read into; 0 when it is unstructured.
    var stepCount: Int
    /// It reached the referee partial (stopped, cut off or failed).
    var partial: Bool
    /// There was something to judge: it was not declined, and some text or a step arrived.
    var hasContent = true
}

/// A verdict ready to be stored.
nonisolated struct VerdictDraft: Hashable, Sendable {
    var attemptMessageID: UUID
    var outcome: RefereeOutcome
    var gapStepIndices: [Int]
    var rationale: String
    var sawPartialAttempt: Bool
}

/// Turns a referee's report into verdicts, failing closed:
/// - an attempt the referee did not judge gets no verdict (it shows "no verdict", never "complete");
/// - an outcome other than "complete" or "gap" is a gap (`RefereeOutcome.fallback`);
/// - "complete" with gap steps listed is a gap, and so is "complete" for an attempt with nothing in it;
/// - several entries for one attempt merge into the least trusting one;
/// - an entry for a letter that names no attempt is ignored.
/// A verdict is only ever "complete" or "gap", so nothing here can reach `humanChecked` (invariant 1).
nonisolated enum VerdictMapper {
    static func map(_ report: RefereeReport, attempts: [AttemptRef]) -> [VerdictDraft] {
        let entries = Dictionary(grouping: report.verdicts) { Self.letter($0.attempt) }
        return attempts.compactMap { attempt in
            guard let judged = entries[Self.letter(attempt.letter)], !judged.isEmpty else { return nil }
            let listed = Set(judged.flatMap(\.gapSteps))
            let saysComplete = judged.allSatisfy { RefereeOutcome(stored: $0.outcome.lowercased()) == .complete }
            let outcome: RefereeOutcome = saysComplete && listed.isEmpty && attempt.hasContent ? .complete : .gap
            let inRange = listed.filter { $0 >= 1 && (attempt.stepCount == 0 || $0 <= attempt.stepCount) }
            return VerdictDraft(attemptMessageID: attempt.messageID, outcome: outcome, gapStepIndices: inRange.sorted(),
                                rationale: judged.map(\.rationale).joined(separator: "\n\n"),
                                sawPartialAttempt: attempt.partial)
        }
    }

    private static func letter(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).uppercased()
    }
}
