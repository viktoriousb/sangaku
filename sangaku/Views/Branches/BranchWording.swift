import Foundation

/// What the Branches screen and the branch sheets say. Kept out of the views, so the words that state what a branch
/// carries and what adopting does are tested.
enum BranchWording {
    static let title = "Branches"
    static let subtitle = "Fork from any message. A dead end keeps why it died, and that reason is sent with every new prompt."
    static let keys = "J / K between nodes"
    static let adoptChecksNothing =
        "Adopting checks nothing: the theorem's status comes from what these steps have earned, from people and referees."
    static let adoptHelp = "Make this attempt the theorem's proof and its branch the main line; adopting checks nothing"

    /// The Adopt button for one attempt, wherever it is offered: "Adopt Model A as Main Line…".
    static func adoptTitle(_ attempt: String) -> String { "Adopt \(attempt) as Main Line…" }

    /// What stands in for the Adopt button once the attempt is adopted.
    static func isMainProof(_ attempt: String) -> String { "\(attempt) is the main line's proof" }
    static let noMessage = "No messages on this branch yet."

    /// A message as a menu or sheet names it: "Model A · Since q | p + 1 and q > p…".
    static func messageLabel(author: String, text: String) -> String {
        "\(author) · \(preview(text))"
    }

    /// The first line of a text, shortened.
    static func preview(_ text: String, limit: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "(no text)" }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// "Model A's attempt", "MK's message", "the referee message of Model C".
    static func message(kind: MessageKind, author: String) -> String {
        let noun = switch kind {
        case .attempt: "attempt"
        case .referee: "referee message"
        case .reply, .refereeReply: "reply"
        case .compute: "computation"
        case .leanDraft: "Lean draft"
        case .prompt, .system: "message"
        }
        return "\(author)'s \(noun)"
    }

    /// "Forked from Model A's attempt on Counting elements."
    static func forkLine(kind: MessageKind, author: String, branch: String) -> String {
        "Forked from \(message(kind: kind, author: author)) on \(branch)."
    }

    /// What a fork carries from its parent.
    static func inherited(_ count: Int) -> String {
        "The first \(Prose.count(count, "message")) come from the parent branch; models on this branch are sent them as earlier conversation, and they are left out first when a window is short."
    }

    /// Who wrote a reason, and from which message: "Written by You, edited from Model A's reply."
    static func provenance(by person: String?, from message: String?) -> String? {
        guard let person else { return nil }
        return "Written by \(person)" + (message.map { ", edited from \($0)" } ?? "") + "."
    }

    /// A branch's standing in words: "main line", "dead end, running".
    static func standing(_ state: BranchState, isMain: Bool, isRunning: Bool) -> String {
        let words = StatusStyle.style(forBranch: state, isMain: isMain).label.lowercased()
        return isRunning ? words + ", running" : words
    }

    /// "Explored by Model A and You · 10:44–10:47 · 3 messages", for a branch's own messages.
    static func explored(by authors: [String], from: Date?, to: Date?, messages: Int) -> String {
        guard messages > 0 else { return noMessage }
        var parts: [String] = []
        if !authors.isEmpty { parts.append("Explored by " + Prose.list(authors)) }
        if let from, let to {
            let (start, end) = (ShortTime.text(from), ShortTime.text(to))
            parts.append(start == end ? start : "\(start)\u{2013}\(end)")
        }
        parts.append(Prose.count(messages, "message"))
        return parts.joined(separator: " · ")
    }

    /// What models are told about a branch, or why they are told nothing.
    static func sent(state: BranchState, inContext: Bool) -> String {
        switch state {
        case .deadEnd where inContext: "Sent with every new prompt on this problem, on every branch."
        case .deadEnd: "Not sent: In Context is off."
        case .parked: "Parked branches are never sent to models."
        case .live: "A live branch is not sent as a dead end."
        }
    }

    /// The adoption, as the main line's panel states it.
    static func adoption(attempt: String, by person: String?, at date: Date?) -> String {
        "Adopted: \(attempt)" + (person.map { ", by \($0)" } ?? "") + (date.map { " · " + ShortTime.text($0) } ?? "") + "."
    }

    /// What adopting will do to the theorem and the main line.
    static func adoptEffect(steps: Int, theorem: String, branch: String, alreadyMain: Bool) -> String {
        "\(theorem)'s proof becomes these \(Prose.count(steps, "step")). "
            + (alreadyMain ? "\(branch) stays the main line." : "\(branch), where the attempt was written, becomes the main line.")
    }

    /// The adopted proof was stopped before it finished.
    static let partialProof = "The adopted proof is partial: its attempt was stopped before it finished."

    /// Where a salvaged lemma came from, and what it rests on.
    static func salvaged(author: String, branch: String) -> String {
        "Salvaged from \(author)'s attempt on \(branch). It rests on those steps, so their reviews and verdict count as they are."
    }

    /// A fan-out a fork cut short: its later attempts are on the parent only.
    static func hiddenAttempts(_ count: Int) -> String {
        "Forked inside this fan-out: \(Prose.count(count, "later attempt")) and any referee pass are on the parent branch, not this one."
    }

    /// The reason sheet's title and confirm button.
    static func reasonTitle(_ mode: ReasonMode) -> (title: String, action: String) {
        switch mode {
        case .deadEnd: ("Mark as Dead End", "Mark as Dead End")
        case .park: ("Park Branch", "Park")
        case .edit: ("Edit Reasons", "Save")
        }
    }

    // MARK: Tree nodes

    /// A node's frame: an attempt or lemma by the status its steps earn, a branch by its lifecycle or as the main line,
    /// the problem by its theorem's displayed status. Never a status colour for adopting (invariant 3).
    static func style(_ node: BranchTree.Node) -> StatusStyle {
        switch node.kind {
        case .problem(_, _, let status, _): StatusStyle.style(for: status ?? .proposed)
        case .branch(let branch): StatusStyle.style(forBranch: branch.state, isMain: branch.isMain)
        case .attempt(let attempt): StatusStyle.style(for: attempt.status)
        case .lemma(let lemma): StatusStyle.style(for: lemma.status)
        }
    }

    /// A node's first line. LaTeX is allowed: it is drawn with `MathText`.
    static func title(_ node: BranchTree.Node) -> String {
        switch node.kind {
        case .problem(let title, let theorem, _, _): (theorem.map { "\($0) · " } ?? "") + (title.isEmpty ? "Untitled problem" : title)
        case .branch(let branch): branch.name
        case .attempt(let attempt): "\(attempt.author)'s attempt"
        case .lemma(let lemma): "\(lemma.label): \(lemma.statementLaTeX)"
        }
    }

    /// A node's second line: how it hangs off its parent and where it stands.
    static func caption(_ node: BranchTree.Node) -> String {
        var parts: [String] = []
        switch node.link {
        case .fork?: parts.append("Forked")
        case .salvaged?: parts.append("Salvaged")
        default: break
        }
        switch node.kind {
        case .problem(_, _, let status, let partialProof):
            parts.append("theorem " + (status ?? .proposed).words)
            if partialProof { parts.append("its adopted proof is partial") }
        case .branch(let branch):
            parts.append(standing(branch.state, isMain: branch.isMain, isRunning: branch.isRunning))
            parts.append(Prose.count(branch.ownMessages, "message") + (branch.inheritedMessages > 0
                ? " + \(branch.inheritedMessages) inherited" : ""))
            if branch.inContext { parts.append("in every prompt") }
        case .attempt(let attempt):
            parts.append(([attempt.progress.headline] + attempt.progress.notes).joined(separator: ", "))
            parts.append(referee(attempt))
            if attempt.isAdopted { parts.append("adopted") }
        case .lemma(let lemma):
            parts.append(lemma.status.words)
        }
        return parts.joined(separator: " · ")
    }

    /// What the referee said about an attempt, and whether it still covers the text: a verdict given before a step
    /// changed is said to be out of date, so the words never claim more than the frame shows (invariant 3).
    static func referee(_ attempt: BranchTree.AttemptFacts) -> String {
        switch attempt.verdict {
        case nil:
            return "no referee verdict"
        case .gap?:
            let steps = attempt.gapSteps.map(String.init)
            return steps.isEmpty ? "referee: gap" : "referee: gap at \(steps.count == 1 ? "step" : "steps") " + Prose.list(steps)
        case .complete?:
            for case .revisedSinceReferee(let steps) in attempt.warnings {
                return "referee: complete, but \(steps.count == 1 ? "step" : "steps") \(Prose.list(steps.map(String.init))) changed since"
            }
            return attempt.warnings.contains(.unrefereed) ? "referee: complete, on text it did not record" : "referee: complete"
        }
    }

    /// What VoiceOver says for a node: its frame's words, its title as spoken (`MathTextComposer`), and its caption,
    /// since the rails are not read.
    static func sentence(_ node: BranchTree.Node, spokenTitle: String) -> String {
        "\(style(node).label): \(spokenTitle). \(caption(node))."
    }
}
