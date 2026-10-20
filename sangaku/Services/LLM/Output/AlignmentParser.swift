import Foundation

/// An aligner's output (`OutputFormat.alignment`), read but not yet trusted: `AlignmentMapper` decides what it may say.
nonisolated struct AlignmentReport: Hashable, Sendable {
    nonisolated struct Entry: Hashable, Sendable {
        var label: String
        var step1: Int
        var step2: Int
        var note: String
        var phrase1: String
        var phrase2: String
        var verdict: String
    }

    var rows: [Entry]
    var summary: String
}

/// Reads an aligner's output whole, or not at all: an alignment that stopped early gives no rows. A string holding a
/// control character (what an undoubled backslash such as `\theta` becomes) fails the whole read.
nonisolated enum AlignmentParser {
    private struct EntryDTO: Decodable {
        let label: String
        let step1: Int
        let step2: Int
        let note: String
        let phrase1: String
        let phrase2: String
        let verdict: String

        enum CodingKeys: String, CodingKey {
            case label, note, verdict
            case step1 = "step_1", step2 = "step_2", phrase1 = "phrase_1", phrase2 = "phrase_2"
        }
    }

    private struct ReportDTO: Decodable {
        let rows: [EntryDTO]
        let summary: String
    }

    static func parse(_ text: String) -> AlignmentReport? {
        guard let dto = try? JSONDecoder().decode(ReportDTO.self, from: Data(text.utf8)),
              let summary = AttemptParser.clean(dto.summary) else { return nil }
        var rows: [AlignmentReport.Entry] = []
        for row in dto.rows {
            guard let label = AttemptParser.clean(row.label), let note = AttemptParser.clean(row.note),
                  let phrase1 = AttemptParser.clean(row.phrase1), let phrase2 = AttemptParser.clean(row.phrase2),
                  let verdict = AttemptParser.clean(row.verdict) else { return nil }
            rows.append(AlignmentReport.Entry(label: label, step1: row.step1, step2: row.step2, note: note,
                                              phrase1: phrase1, phrase2: phrase2, verdict: verdict))
        }
        return AlignmentReport(rows: rows, summary: summary)
    }
}

/// An aligner's answer ready to be stored as a comparison's model rows.
nonisolated struct AlignmentDraft: Hashable, Sendable {
    var rows: [AlignmentRow]
    var summary: String
}

/// Turns an aligner's report into rows, failing closed:
/// - a step number outside its attempt drops the row; a row with no step at all is dropped;
/// - a step already used by an earlier row drops the later row;
/// - an unknown verdict reads as "diverge" (`AlignmentVerdict.fallback`); a pair called one-sided diverges, and a
///   single step called a pair stands alone;
/// - a key phrase is kept only on a diverging pair, and only where it is found in that step's text with every formula
///   left whole (`KeyPhrase.locate`, invariant 16);
/// - each row records the revision of each step the model was shown, so a later revision makes it out of date.
/// With no row left, there is nothing to store: the comparison keeps whatever it had. Steps the model left out are
/// paired by label when the comparison is read, so nothing is ever dropped from the table.
nonisolated enum AlignmentMapper {
    static func map(_ report: AlignmentReport, basis: AlignmentBasis) -> AlignmentDraft? {
        let first = Dictionary(basis.first.steps.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let second = Dictionary(basis.second.steps.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<UUID>()
        var rows: [AlignmentRow] = []
        for entry in report.rows {
            let a = entry.step1 == 0 ? nil : first[entry.step1]
            let b = entry.step2 == 0 ? nil : second[entry.step2]
            guard (entry.step1 == 0 || a != nil), (entry.step2 == 0 || b != nil), a != nil || b != nil,
                  !(a.map { used.contains($0.stepID) } ?? false), !(b.map { used.contains($0.stepID) } ?? false)
            else { continue }
            let said = verdict(entry.verdict)
            let verdict: AlignmentVerdict = switch (a, b) {
            case (_?, _?): said == .equivalent ? .equivalent : .diverge
            case (_?, nil): .onlyA
            default: .onlyB
            }
            let note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(AlignmentRow(
                stepAID: a?.stepID, stepBID: b?.stepID, label: entry.label.trimmingCharacters(in: .whitespacesAndNewlines),
                verdict: verdict.rawValue, note: note.isEmpty ? nil : note,
                keyPhraseA: verdict == .diverge ? phrase(entry.phrase1, in: a) : nil,
                keyPhraseB: verdict == .diverge ? phrase(entry.phrase2, in: b) : nil,
                revisionAID: a?.revisionID, revisionBID: b?.revisionID))
            if let a { used.insert(a.stepID) }
            if let b { used.insert(b.stepID) }
        }
        guard !rows.isEmpty else { return nil }
        return AlignmentDraft(rows: rows, summary: report.summary.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func verdict(_ raw: String) -> AlignmentVerdict {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "equivalent": .equivalent
        case "only_1": .onlyA
        case "only_2": .onlyB
        default: .fallback
        }
    }

    private static func phrase(_ phrase: String, in step: AlignmentBasis.Step?) -> String? {
        guard let step, KeyPhrase.locate(phrase, in: step.text) != nil else { return nil }
        return phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
