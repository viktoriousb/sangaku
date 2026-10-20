import Foundation

/// What Review says about a step, from its standing and who is who. Kept out of the views, so the words that state
/// trust (who checked, what is blocked, what a revision resets) are tested.
enum ReviewWording {
    // MARK: Chips and lines

    /// The step's chips: its standing with people, a re-check flag, then the referee's word. Each has glyph and words.
    static func chips(for step: StepReview, authors: AuthorDirectory) -> [StatusStyle] {
        let standing = step.standing
        var chips: [StatusStyle] = []
        switch standing.human {
        case .unchecked:
            chips.append(StepReviewStyle.unchecked)
        case .checked:
            let names = Prose.list(reviewers(standing.checks).map(authors.initials(ofPerson:)))
            chips.append(StepReviewStyle.checked(names + (standing.latestCheckAt.map { " · " + ShortTime.text($0) } ?? "")))
        case .objected:
            chips += standing.openObjections.map {
                StepReviewStyle.objection($0.verdict, by: authors.initials(ofPerson: $0.reviewerID))
            }
        }
        if let recheck = standing.recheck { chips.append(StepReviewStyle.recheck(recheck)) }
        if let model = StepReviewStyle.model(standing.model, referee: authors.refereeLetter(standing.model.referee),
                                             personChecked: standing.countsAsChecked) {
            chips.append(model)
        }
        return chips
    }

    /// Each reviewer once, in the order given.
    static func reviewers(_ reviews: [ReviewFact]) -> [UUID?] {
        var seen: Set<UUID?> = []
        return reviews.map(\.reviewerID).filter { seen.insert($0).inserted }
    }

    /// "Written by Model A, revised by You · 11:05 (version 2)".
    static func provenanceLine(_ step: StepReview, authors: AuthorDirectory) -> String {
        let provenance = step.provenance
        guard let original = provenance.original, let current = provenance.current else { return "No recorded author" }
        var line = "Written by \(authors.name(of: original.author))"
        if provenance.isRevised {
            line += ", revised by \(authors.name(of: current.author)) · \(ShortTime.text(current.createdAt))"
                + " (version \(current.number))"
        }
        return line
    }

    /// "? Unclear, raised by You · 11:14".
    static func objectionLine(_ objection: ReviewFact, authors: AuthorDirectory) -> String {
        "\(objection.verdict.glyph) \(objection.verdict.title), raised by \(authors.name(ofPerson: objection.reviewerID))"
            + " · \(ShortTime.text(objection.createdAt))"
    }

    /// "? Unclear by You, dismissed by MK · 11:20: The parity argument closes it."
    static func dismissalLine(_ objection: ReviewFact, authors: AuthorDirectory) -> String {
        let when = objection.dismissedAt.map { " · " + ShortTime.text($0) } ?? ""
        return "\(objection.verdict.glyph) \(objection.verdict.title) by \(authors.name(ofPerson: objection.reviewerID)), "
            + "dismissed by \(authors.name(ofPerson: objection.dismissedByID))\(when): \(objection.dismissalReason ?? "")"
    }

    /// "? Unclear by You, withdrawn · 11:20".
    static func withdrawalLine(_ review: ReviewFact, authors: AuthorDirectory) -> String {
        let when = review.withdrawnAt.map { " · " + ShortTime.text($0) } ?? ""
        return "\(review.verdict.glyph) \(review.verdict.title) by \(authors.name(ofPerson: review.reviewerID)), withdrawn\(when)"
    }

    /// One line of a step's history.
    static func historyLine(_ entry: HistoryEntry, step: StepReview, authors: AuthorDirectory) -> String {
        let time = ShortTime.text(entry.date)
        switch entry.kind {
        case .version(let version):
            var changes: [String] = []
            if version.changedText { changes.append("text changed") }
            if version.changedEstablishes { changes.append("what it establishes changed to “\(version.establishes)”") }
            return "Version \(version.number)\(version.isCurrent ? ", current," : "") by \(authors.name(of: version.author))"
                + " · \(time)" + (changes.isEmpty ? "" : " · " + changes.joined(separator: ", "))
        case .review(let review):
            let on = step.versionLabel(of: review.revisionID).map { " on \($0)" } ?? ""
            return "\(review.verdict.glyph) \(review.verdict.title) by \(authors.name(ofPerson: review.reviewerID))"
                + " · \(time)\(on)"
        case .dismissal(let review):
            return dismissalLine(review, authors: authors)
        case .withdrawal(let review):
            return withdrawalLine(review, authors: authors)
        case .comment(let comment):
            return "Comment by \(authors.name(of: comment.author)) · \(time)"
        }
    }

    /// Who wrote the attempt's steps, in order of appearance, for the margin legend.
    static func legend(_ state: AttemptReviewState, authors: AuthorDirectory) -> [AuthorDirectory.AuthorMark] {
        var marks: [AuthorDirectory.AuthorMark] = []
        for step in state.steps {
            for version in step.provenance.versions {
                let mark = authors.mark(of: version.author)
                if !marks.contains(mark) { marks.append(mark) }
            }
        }
        return marks
    }

    // MARK: Before and after an action

    /// What saving a revision resets, said before it happens. `establishes` is what the new version will say.
    static func revisionConsequences(_ step: StepReview, establishes: String, authors: AuthorDirectory) -> String {
        let standing = step.standing
        var parts = ["The new version is recorded as yours; the earlier ones stay in the history."]
        let checkers = reviewers(standing.checks)
        if !checkers.isEmpty {
            parts.append("Checks by \(Prose.list(checkers.map(authors.name(ofPerson:)))) on this version stop counting.")
        }
        if !standing.openObjections.isEmpty { parts.append("Open objections on this version close.") }
        if standing.model.passes {
            parts.append("\(authors.refereeLetter(standing.model.referee))'s check no longer covers the step.")
        }
        if StepStandings.normalized(establishes) != StepStandings.normalized(step.establishes) {
            parts.append("What it establishes changes, so later checked steps are flagged for re-check.")
        }
        return parts.joined(separator: " ")
    }

    /// What VoiceOver says after withdrawing one's own mark.
    static func withdrawalAnnouncement(_ review: ReviewFact, step: StepReview) -> String {
        review.verdict == .correct
            ? "Your check on step \(step.index) withdrawn"
            : "Your \(review.verdict.title.lowercased()) on step \(step.index) withdrawn; it no longer blocks the step"
    }

    /// What VoiceOver says after a mark. `step` is the step as it stood when the key was pressed. A ✓ beside an open
    /// objection is never announced as counting (invariants 8 and 11).
    static func announcement(_ outcome: ReviewManager.MarkOutcome, verdict: ReviewVerdict, step: StepReview) -> String {
        let blocked = verdict == .correct && !step.standing.openObjections.isEmpty
        switch outcome {
        case .recorded where blocked, .alreadyChecked where blocked:
            return "Step \(step.index): your check is recorded, but an open objection still blocks it"
        case .recorded:
            return "Step \(step.index) \(verdict.pastTense)"
        case .alreadyChecked:
            return "Step \(step.index): your check already counts"
        case .alreadyRaised:
            return "Step \(step.index): your \(verdict.title.lowercased()) is already open"
        }
    }
}
