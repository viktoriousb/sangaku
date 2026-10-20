import Foundation

/// One step as Compare shows it: its current text and what it establishes. Never its author.
nonisolated struct AlignedStep: Hashable, Sendable, Identifiable {
    var id: UUID
    var index: Int
    var establishes: String
    /// The current revision's text.
    var text: String
    var revisionID: UUID?
    /// A person's ✓ counts on the current revision, so the text is drawn in full ink (invariant 3).
    var countsAsChecked = false
}

/// One side of a comparison: an attempt's steps in index order.
nonisolated struct AlignedAttempt: Hashable, Sendable, Identifiable {
    var id: UUID
    var steps: [AlignedStep]
    /// Stopped or cut off: what is there is incomplete.
    var isPartial = false
}

/// What a row of the comparison says. Exactly one per row.
nonisolated enum RowState: Hashable, Sendable {
    /// Judged equivalent, on the text both steps have now.
    case equivalent
    /// Judged to say different things, on the text both steps have now.
    case diverge
    /// One step with no counterpart in the other attempt.
    case onlyOne
    /// Paired by what the steps establish, not yet judged by a model or a person.
    case notCompared
    /// Judged, but a step changed since: the judgement no longer covers the text.
    case stale
}

/// Who decided a row.
nonisolated enum RowJudge: Hashable, Sendable {
    case model, person, none
}

/// One row of the comparison table.
nonisolated struct CompareRow: Hashable, Sendable, Identifiable {
    var id: RowKey
    var a: AlignedStep?
    var b: AlignedStep?
    var label: String
    var state: RowState
    var judgedBy: RowJudge
    /// The judgement, kept on an out-of-date row so the view can say what it was.
    var verdict: AlignmentVerdict?
    var note: String?
    /// Where the steps part ways, as UTF-16 offsets into each step's text. Only on a current diverging row.
    var markA: Range<Int>?
    var markB: Range<Int>?
}

/// Everything a comparison is derived from.
nonisolated struct ComparisonFacts: Hashable, Sendable {
    var first: AlignedAttempt
    var second: AlignedAttempt
    /// The model's last readable rows; nil when no model has aligned these attempts.
    var modelRows: [AlignmentRow]?
    var modelRowsUnreadable = false
    var corrections: [AlignmentCorrection] = []
    var correctionsUnreadable = false
}

/// Two attempts' steps paired by what they establish. Derived on every read from three layers: a person's
/// corrections over the model's rows over the pairing by label. Every step of both attempts is in exactly one row,
/// whatever the stored layers say. Nothing here is a check: no row changes a step's review or a statement's status.
nonisolated struct ComparisonState: Hashable, Sendable {
    var first: AlignedAttempt
    var second: AlignedAttempt
    var rows: [CompareRow]
    var summary: CompareSummary
    var hasModelRows: Bool
    var modelRowsUnreadable: Bool
    var correctionsUnreadable: Bool

    init(_ facts: ComparisonFacts) {
        first = facts.first
        second = facts.second
        modelRowsUnreadable = facts.modelRowsUnreadable
        correctionsUnreadable = facts.correctionsUnreadable
        let stepsA = Dictionary(facts.first.steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stepsB = Dictionary(facts.second.steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var pairing = Pairing()
        // 1. The model's rows: a row counts only if its steps exist and are not already in an earlier row.
        var modelRow: [RowKey: AlignmentRow] = [:]
        for row in facts.modelRowsUnreadable ? [] : facts.modelRows ?? [] {
            guard row.stepAID != nil || row.stepBID != nil,
                  row.stepAID.map({ stepsA[$0] != nil }) ?? true, row.stepBID.map({ stepsB[$0] != nil }) ?? true,
                  !pairing.isDecided(a: row.stepAID), !pairing.isDecided(b: row.stepBID) else { continue }
            let key = RowKey(a: row.stepAID, b: row.stepBID)
            switch (row.stepAID, row.stepBID) {
            case let (a?, b?): pairing.pair(a, b)
            case let (a?, nil): pairing.singlesA[a] = .model
            case let (nil, b?): pairing.singlesB[b] = .model
            case (nil, nil): continue
            }
            modelRow[key] = row
        }
        hasModelRows = !modelRow.isEmpty

        // 2. A person's corrections, replayed in the order they were made. Separating two steps, or pairing either
        //    with another step, withdraws the person's judgement of them: pairing them again starts unjudged.
        var personVerdict: [RowKey: AlignmentCorrection] = [:]
        for correction in facts.correctionsUnreadable ? [] : facts.corrections {
            let (a, b) = (correction.stepAID, correction.stepBID)
            guard stepsA[a] != nil, stepsB[b] != nil else { continue }
            switch correction.action {
            case .pair:
                pairing.pair(a, b)
                // Each step leaves whatever it was paired with, by the model, a person or a label.
                personVerdict = personVerdict.filter { key, _ in key == correction.key || (key.a != a && key.b != b) }
            case .unpair:
                pairing.separate(a, b)
                personVerdict[correction.key] = nil
            case .judge:
                personVerdict[correction.key] = correction
            case .clear:
                personVerdict[correction.key] = nil
            }
        }

        // 3. Whatever is left is paired by label: never judged.
        let freeA = facts.first.steps.filter { !pairing.isDecided(a: $0.id) }
        let freeB = facts.second.steps.filter { !pairing.isDecided(b: $0.id) }
        for (a, b) in LabelPairing.pair(freeA, freeB) { pairing.pair(a.id, b.id) }

        // 4. Rows.
        var rows: [CompareRow] = []
        for step in facts.first.steps {
            if let partner = pairing.partnerA[step.id], let other = stepsB[partner] {
                rows.append(Self.pairedRow(step, other, model: modelRow[RowKey(a: step.id, b: partner)],
                                           person: personVerdict[RowKey(a: step.id, b: partner)]))
            } else {
                rows.append(Self.singleRow(a: step, b: nil, judge: pairing.singlesA[step.id] ?? .none,
                                           model: modelRow[RowKey(a: step.id, b: nil)]))
            }
        }
        for step in facts.second.steps where pairing.partnerB[step.id] == nil {
            rows.append(Self.singleRow(a: nil, b: step, judge: pairing.singlesB[step.id] ?? .none,
                                       model: modelRow[RowKey(a: nil, b: step.id)]))
        }
        self.rows = RowOrder.order(rows)
        summary = CompareSummary(self.rows)
    }

    var pair: ComparedPair { ComparedPair(first: first.id, second: second.id) }

    subscript(row key: RowKey?) -> CompareRow? { rows.first { $0.id == key } }

    func visibleRows(_ filter: CompareFilter) -> [CompareRow] {
        filter == .all ? rows : rows.filter { $0.state != .equivalent }
    }

    /// Rotor lists.
    var divergingRowIDs: [RowKey] { rows.filter { $0.state == .diverge }.map(\.id) }
    var unmatchedRowIDs: [RowKey] { rows.filter { $0.state == .onlyOne }.map(\.id) }
    var staleRowIDs: [RowKey] { rows.filter { $0.state == .stale }.map(\.id) }

    /// A pair of steps. The model's note and marks are shown only while its reading covers the text both steps have
    /// now; a person's judgement on the current text does not make an older reading current.
    private static func pairedRow(_ a: AlignedStep, _ b: AlignedStep, model: AlignmentRow?,
                                  person: AlignmentCorrection?) -> CompareRow {
        let current = model.map { isCurrent(a, $0.revisionAID) && isCurrent(b, $0.revisionBID) } ?? false
        var row = CompareRow(id: RowKey(a: a.id, b: b.id), a: a, b: b, label: label(model?.label, a, b),
                             state: .notCompared, judgedBy: .none,
                             note: current ? model.flatMap(\.note).flatMap(nonEmpty) : nil)
        if let person {
            row.judgedBy = .person
            row.verdict = AlignmentVerdict(stored: person.verdict) == .equivalent ? .equivalent : .diverge
            row.state = isCurrent(a, person.revisionAID) && isCurrent(b, person.revisionBID) ? state(row.verdict) : .stale
        } else if let model {
            row.judgedBy = .model
            // A pair the model called one-sided is at least not the same claim.
            row.verdict = model.alignmentVerdict == .equivalent ? .equivalent : .diverge
            row.state = current ? state(row.verdict) : .stale
        }
        if row.state == .diverge, current, let model {
            row.markA = KeyPhrase.locate(model.keyPhraseA, in: a.text)
            row.markB = KeyPhrase.locate(model.keyPhraseB, in: b.text)
        }
        return row
    }

    /// A step with no counterpart. The model's "no counterpart" is out of date once the step is revised; a person's
    /// separation, and a step no label matched, are not readings of its text.
    private static func singleRow(a: AlignedStep?, b: AlignedStep?, judge: RowJudge, model: AlignmentRow?) -> CompareRow {
        let step = a ?? b
        let current = switch (a, b, model) {
        case (let a?, _, let model?): isCurrent(a, model.revisionAID)
        case (nil, let b?, let model?): isCurrent(b, model.revisionBID)
        default: true
        }
        let byModel = judge == .model
        return CompareRow(id: RowKey(a: a?.id, b: b?.id), a: a, b: b,
                          label: nonEmpty(model?.label ?? "") ?? step?.establishes ?? "",
                          state: byModel && !current ? .stale : .onlyOne, judgedBy: judge,
                          verdict: a == nil ? .onlyB : .onlyA,
                          note: byModel && current ? model.flatMap(\.note).flatMap(nonEmpty) : nil)
    }

    /// The judgement covers the step only if it was given on the revision the step has now. An unrecorded
    /// revision covers nothing.
    private static func isCurrent(_ step: AlignedStep, _ revision: UUID?) -> Bool {
        revision != nil && revision == step.revisionID
    }

    private static func state(_ verdict: AlignmentVerdict?) -> RowState {
        verdict == .equivalent ? .equivalent : .diverge
    }

    private static func label(_ model: String?, _ a: AlignedStep, _ b: AlignedStep) -> String {
        nonEmpty(model ?? "") ?? nonEmpty(a.establishes) ?? b.establishes
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension CompareRow {
    /// The marked key phrase of side 1 or 2, as it stands in that step's text.
    func phrase(_ side: Int) -> String? {
        guard let step = side == 1 ? a : b, let mark = side == 1 ? markA : markB else { return nil }
        let utf16 = step.text.utf16
        guard mark.upperBound <= utf16.count else { return nil }
        let lower = utf16.index(utf16.startIndex, offsetBy: mark.lowerBound)
        let upper = utf16.index(utf16.startIndex, offsetBy: mark.upperBound)
        return String(utf16[lower..<upper])
    }
}

/// Which steps are paired, and which were decided to stand alone (by the model, or by a person separating them).
private nonisolated struct Pairing {
    var partnerA: [UUID: UUID] = [:]
    var partnerB: [UUID: UUID] = [:]
    var singlesA: [UUID: RowJudge] = [:]
    var singlesB: [UUID: RowJudge] = [:]

    func isDecided(a: UUID?) -> Bool { a.map { partnerA[$0] != nil || singlesA[$0] != nil } ?? false }
    func isDecided(b: UUID?) -> Bool { b.map { partnerB[$0] != nil || singlesB[$0] != nil } ?? false }

    /// Pairs the two steps. Their former partners are left free, to be paired by label again.
    mutating func pair(_ a: UUID, _ b: UUID) {
        if let old = partnerA[a] { partnerB[old] = nil }
        if let old = partnerB[b] { partnerA[old] = nil }
        partnerA[a] = b
        partnerB[b] = a
        singlesA[a] = nil
        singlesB[b] = nil
    }

    /// Separates two steps, as a person decided: if they are paired, each then stands alone; a step paired with
    /// something else keeps that pair. Either way, no pairing by label brings the two together again.
    mutating func separate(_ a: UUID, _ b: UUID) {
        if partnerA[a] == b {
            partnerA[a] = nil
            partnerB[b] = nil
        }
        if partnerA[a] == nil { singlesA[a] = .person }
        if partnerB[b] == nil { singlesB[b] = .person }
    }
}

/// Pairing by what the steps establish: the k-th step of one attempt with a given label pairs with the k-th of the
/// other. Never a judgement: label-paired rows are "not compared".
nonisolated enum LabelPairing {
    static func key(_ establishes: String) -> String {
        StepStandings.normalized(establishes).lowercased()
    }

    static func pair(_ first: [AlignedStep], _ second: [AlignedStep]) -> [(AlignedStep, AlignedStep)] {
        var waiting: [String: [AlignedStep]] = [:]
        for step in second where !key(step.establishes).isEmpty {
            waiting[key(step.establishes), default: []].append(step)
        }
        var pairs: [(AlignedStep, AlignedStep)] = []
        for step in first {
            let label = key(step.establishes)
            guard !label.isEmpty, var candidates = waiting[label], !candidates.isEmpty else { continue }
            pairs.append((step, candidates.removeFirst()))
            waiting[label] = candidates
        }
        return pairs
    }
}

/// Rows in reading order: by the first attempt's steps, with a step only in the second attempt placed after the
/// row holding the nearest earlier step of the second attempt.
nonisolated enum RowOrder {
    static func order(_ rows: [CompareRow]) -> [CompareRow] {
        let withA = rows.filter { $0.a != nil }
        func key(_ row: CompareRow) -> (Int, Int, Int) {
            if let a = row.a { return (a.index, 0, row.b?.index ?? 0) }
            let index = row.b?.index ?? 0
            let anchor = withA.filter { ($0.b?.index ?? .max) < index }.map { $0.a?.index ?? 0 }.max() ?? 0
            return (anchor, 1, index)
        }
        return rows.sorted { key($0) < key($1) }
    }
}

/// The table's counts. Each row is in exactly one; an out-of-date row is never counted as equivalent.
nonisolated struct CompareSummary: Hashable, Sendable {
    var equivalent = 0
    var diverge = 0
    var onlyOne = 0
    var notCompared = 0
    var stale = 0

    init(_ rows: [CompareRow]) {
        for row in rows {
            switch row.state {
            case .equivalent: equivalent += 1
            case .diverge: diverge += 1
            case .onlyOne: onlyOne += 1
            case .notCompared: notCompared += 1
            case .stale: stale += 1
            }
        }
    }
}

/// "All steps" or "Differences only". Differences hide only rows judged equivalent on the current text, so nothing
/// unjudged or out of date is ever hidden.
nonisolated enum CompareFilter: String, CaseIterable, Hashable, Sendable {
    case all, differences
}

/// Where a key phrase sits in a step's current text.
nonisolated enum KeyPhrase {
    /// The first exact occurrence, as UTF-16 offsets. Nil when the phrase is empty, no longer in the text, or cuts a
    /// formula there (invariant 16): a phrase is marked, and spelled out, only where it leaves every formula whole.
    static func locate(_ phrase: String?, in text: String) -> Range<Int>? {
        guard let phrase = phrase?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty,
              let range = text.range(of: phrase) else { return nil }
        let utf16 = text.utf16
        let mark = utf16.distance(from: utf16.startIndex, to: range.lowerBound)
            ..< utf16.distance(from: utf16.startIndex, to: range.upperBound)
        return pieces(text, mark: mark) == nil ? nil : mark
    }

    /// The text cut at `mark` into the text before, the marked text and the text after. Nil unless each piece holds
    /// whole formulas, exactly the text's own, and the marked text holds no displayed formula.
    static func pieces(_ text: String, mark: Range<Int>) -> [String]? {
        let utf16 = text.utf16
        guard !mark.isEmpty, mark.lowerBound >= 0, mark.upperBound <= utf16.count,
              let lower = String.Index(utf16.index(utf16.startIndex, offsetBy: mark.lowerBound), within: text),
              let upper = String.Index(utf16.index(utf16.startIndex, offsetBy: mark.upperBound), within: text)
        else { return nil }
        let pieces = [String(text[..<lower]), String(text[lower..<upper]), String(text[upper...])]
        let segmented = pieces.map(ProseSegmenter.segments)
        let unterminated = segmented.joined().contains { if case .unterminated = $0 { true } else { false } }
        let displayed = segmented[1].contains { if case .math(_, .display) = $0 { true } else { false } }
        // A cut at "\(" leaves "\" before and "(…\)" after: no piece is unterminated, but a formula is gone.
        let same = formulas(segmented.joined()) == formulas(ProseSegmenter.segments(text))
        return unterminated || displayed || !same ? nil : pieces
    }

    private static func formulas(_ segments: some Sequence<ProseSegment>) -> [String] {
        segments.compactMap { if case .math(let latex, _) = $0 { latex } else { nil } }
    }
}
