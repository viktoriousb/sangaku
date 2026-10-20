import Foundation

/// What Compare says. Kept out of the views, so the words that state what a comparison means are tested.
enum CompareWording {
    static let title = "Two attempts, aligned"
    static let subtitle = "Rows pair steps by what they establish, not by position, so reworded or reordered steps still line up."
    static let noMatch = "No matching step"
    static let noMatchPartial = "No matching step: this attempt stopped before it finished"

    /// "Attempt 1": a side, as Compare names it whoever wrote it.
    nonisolated static func attempt(_ side: Int) -> String { "Attempt \(side)" }
    static let neverACheck = "A comparison is a reading, never a check: no row changes a step's review or a statement's status."

    /// The summary chips, glyph and words, for the counts that are not zero.
    static func chips(_ summary: CompareSummary) -> [StatusStyle] {
        func chip(_ state: RowState, _ count: Int, _ words: String) -> StatusStyle? {
            guard count > 0 else { return nil }
            var style = CompareRowStyle.style(for: state)
            style.label = words
            return style
        }
        return [
            chip(.equivalent, summary.equivalent, Prose.count(summary.equivalent, "row") + " equivalent"),
            chip(.diverge, summary.diverge, summary.diverge == 1 ? "1 divergence" : "\(summary.diverge) divergences"),
            chip(.onlyOne, summary.onlyOne, Prose.count(summary.onlyOne, "step") + " with no match"),
            chip(.notCompared, summary.notCompared, Prose.count(summary.notCompared, "row") + " not compared"),
            chip(.stale, summary.stale, Prose.count(summary.stale, "row") + " out of date"),
        ].compactMap { $0 }
    }

    /// The row's verdict chip.
    static func verdict(_ row: CompareRow) -> StatusStyle {
        CompareRowStyle.style(for: row.state, side: row.state == .onlyOne ? (row.a != nil ? 1 : 2) : nil)
    }

    /// Who decided the row, in words.
    static func judged(_ row: CompareRow) -> String {
        switch (row.state, row.judgedBy) {
        case (.onlyOne, .model): "no counterpart, by a model"
        case (.onlyOne, .person): "separated by you"
        case (.onlyOne, .none): "no step with the same label"
        case (.notCompared, _): "paired by what they establish, not compared"
        case (.stale, _): stale(row)
        case (_, .person): "judged by you"
        case (_, .model): "judged by a model"
        case (_, .none): "not compared"
        }
    }

    /// An out-of-date row: what it was judged, and why it no longer counts.
    static func stale(_ row: CompareRow) -> String {
        if row.a == nil || row.b == nil { return "no counterpart, by a model; the step changed since" }
        let was = row.verdict == .equivalent ? "equivalent" : "diverging"
        return "judged \(was) \(row.judgedBy == .person ? "by you" : "by a model"); a step changed since"
    }

    /// "Where they part: …", for the key phrase of a diverging row, spelled out in case the mark cannot be drawn.
    static func partsAt(_ phrase: String?) -> String? {
        phrase.map { "Where they part: \($0)" }
    }

    /// Where the comparison came from: "Aligned by Model C at 11:16." or by "the referee" while the authors are hidden.
    static func status(hasModelRows: Bool, alignedAt: Date?, aligner: String) -> String {
        guard hasModelRows else { return "Paired by what the steps establish; not compared yet." }
        return "Aligned by \(aligner)" + (alignedAt.map { " at " + ShortTime.text($0) } ?? "") + "."
    }

    /// "Steps 1–4 match A's": a run of steps the thread collapses.
    static func matchRun(_ run: ClosedRange<Int>, other letter: String) -> String {
        "Steps \(run.lowerBound)–\(run.upperBound) match \(letter)'s"
    }

    /// The thread's banner over a fan-out whose attempts part ways.
    static func divergence(_ row: CompareRow) -> String {
        "The attempts part ways at \u{201C}\(row.label)\u{201D}."
    }

    static func holds(_ verdict: HoldsVerdict) -> String {
        switch verdict {
        case .first: "\(attempt(1)) holds"
        case .second: "\(attempt(2)) holds"
        case .both: "Both hold"
        case .neither: "Neither holds"
        }
    }

    /// A stored verdict, or one this version of sangaku cannot read.
    static func recorded(_ verdict: HoldsVerdict?, at date: Date?) -> String {
        "Recorded: " + (verdict.map(holds) ?? "a verdict this version cannot read")
            + (date.map { " · " + ShortTime.text($0) } ?? "")
    }

    /// Why the last alignment request stored nothing.
    static func storedNothing(_ outcome: MessageOutcome) -> String {
        let why = switch outcome {
        case .interrupted: "it was stopped."
        case .cutOff: "it was cut off at the output limit."
        case .declined: "the provider declined it."
        case .failed(_, let message): message
        case .endedEarly(let reason): "it ended early (\(reason))."
        case .complete, .streaming: "its answer could not be read."
        }
        return "The last alignment stored nothing: \(why) The earlier rows are kept."
    }

    /// The same, while blind, when the provider's words may name a model.
    static let storedNothingWithheld =
        "The last alignment stored nothing: it failed, and the error is hidden while blind as it may name a model. The earlier rows are kept."

    /// "step 5 of Attempt 2 · Model B": a step as the questions name it, once the authors may be shown.
    private static func step(_ step: AlignedStep, side: Int, identity: CompareIdentity) -> String {
        "step \(step.index) of \(identity.title(side))"
    }

    /// What is sent to the author of `side`'s step, asking for a repair. Shown, and editable, before it is sent.
    static func repairRequest(_ row: CompareRow, side: Int, identity: CompareIdentity) -> String? {
        guard let mine = side == 1 ? row.a : row.b else { return nil }
        let other = side == 1 ? row.b : row.a
        var lines = ["In Compare, your \(step(mine, side: side, identity: identity)) was set against "
                     + (other.map { "\(step($0, side: 3 - side, identity: identity))." }
                        ?? "the other attempt, which has no matching step.")]
        lines.append("What the row establishes: \(row.label)")
        if let note = row.note { lines.append("The comparison's note: \(note)") }
        lines.append("Your step \(mine.index): \(mine.text)")
        if let other { lines.append("The other attempt's step \(other.index): \(other.text)") }
        lines.append("Repair your step \(mine.index) if it is wrong, or explain why it holds.")
        return lines.joined(separator: "\n\n")
    }

    /// What is sent to the referee about one row. Shown, and editable, before it is sent.
    static func refereeRequest(_ row: CompareRow, identity: CompareIdentity) -> String {
        var lines = ["In Compare, one row of the two attempts asks for your judgement. What it establishes: \(row.label)"]
        if let a = row.a { lines.append("Step \(a.index) of \(identity.title(1)): \(a.text)") }
        if let b = row.b { lines.append("Step \(b.index) of \(identity.title(2)): \(b.text)") }
        if let note = row.note { lines.append("The comparison's note: \(note)") }
        lines.append("Which of these holds, and why? Give a counterexample if one claim is false.")
        return lines.joined(separator: "\n\n")
    }

    /// An alignment request's estimate before it is sent, as the composer words one (`UsageFormat.estimate`). The
    /// model whose price is unknown is named only once the authors may be shown.
    static func estimate(_ recipient: SendPlan.Recipient, identity: CompareIdentity) -> String {
        UsageFormat.estimate(tokens: recipient.totalTokens, cost: recipient.cost, outputCeiling: recipient.outputCeiling,
                             model: identity.hidden ? nil : recipient.model.displayName)
            .joined(separator: " · ")
    }

    /// What was left out of the aligner's context to fit its window (invariant 5), or nil when nothing was.
    static func leftOut(_ recipient: SendPlan.Recipient) -> [String]? {
        switch recipient.fit {
        case .dropped?:
            recipient.dropped.map { "\($0.kind): \($0.title) · ≈ \(UsageFormat.tokens($0.tokens)) tokens" }
        default: nil
        }
    }
}
