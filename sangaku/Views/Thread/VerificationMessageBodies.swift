import SwiftUI

/// A computation cell in the thread: its claim, scope and exact code, and Run beside the code it runs (invariant 14),
/// then how its latest run ended and what it printed. What the code reports is evidence, never a status.
struct ComputeCellBody: View {
    let message: Message
    let cell: ComputeCell
    let authors: AuthorDirectory

    @Environment(\.computeService) private var compute
    @Environment(\.toolSettings) private var settings
    @Environment(\.branchActions) private var branchActions

    var body: some View {
        let isModel = if case .model = message.author { true } else { false }
        let state = compute?.state(of: cell) ?? .waiting
        let statement = (message.branch?.problem?.statements ?? []).first { $0.stableID == cell.statementID }
        let tool = ToolID(cell.tool)
        let latest = cell.latestRun
        let fact = latest.flatMap { run in statement.map { EvidenceFact.read(run, statement: $0.stableID, refuted: $0.refutationAcceptedByID != nil) } }
        VStack(alignment: .leading, spacing: 8) {
            if !message.bodyLaTeX.isEmpty {
                MathText(message.bodyLaTeX)
                    .foregroundStyle(isModel ? StatusStyle.style(for: .proposed).ink.color : ColorToken.ink.color)
            }
            FlowLayout(spacing: 8, lineSpacing: 6) {
                StatusBadge(style: StatusStyle.style(for: state))
                Text(tool.displayName).font(.callout.weight(.medium))
                if let statement {
                    Button("Attached to \(statement.label)") { branchActions?(.revealStatement(statement.stableID)) }
                        .buttonStyle(.link)
                        .disabled(branchActions == nil)
                } else {
                    Text(VerificationError.noStatementAttached.message).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !cell.claim.isEmpty { MathText("Claim: " + cell.claim).font(.callout) }
            // The scope is a person's or a model's prose, with mathematics; only code and output are shown raw.
            MathText("Scope: " + cell.scope).font(.callout).textSelection(.enabled)
            ToolTextBox(text: cell.code, label: "Code", copyTitle: "Copy Code")
            FlowLayout(spacing: 8, lineSpacing: 6) {
                CellActions(message: message, cell: cell)
            }
            if settings?.resolution(tool).path == nil {
                Text(VerificationError.toolNotSetUp(tool).message).font(.caption).foregroundStyle(.secondary)
            }
            if let failure = compute?.lastFailure[cell.stableID] {
                Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(ColorToken.delicate.color)
            }
            if let fact {
                RunSummary(fact: fact, authors: authors)
            }
        }
    }
}

/// What a cell offers, beside its code and in its message's context menu alike: Run (or Run Again, or Stop) and Edit
/// as My Computation. Run carries the digest of the code as drawn now (invariant 14).
struct CellActions: View {
    let message: Message
    let cell: ComputeCell

    @Environment(\.computeService) private var compute
    @Environment(\.toolSettings) private var settings
    @Environment(\.verificationActions) private var actions

    var body: some View {
        let running = compute?.isRunning(cell: cell.stableID) ?? false
        let attached = (message.branch?.problem?.statements ?? []).contains { $0.stableID == cell.statementID }
        let shown = TextDigest(of: cell.code)
        if running {
            Button("Stop") { actions?(.stopCell(cell.stableID)) }
                .disabled(actions == nil)
        } else {
            Button(cell.latestRun == nil ? "Run" : "Run Again") {
                actions?(.runCell(messageID: message.stableID, shown: shown))
            }
            .disabled(actions == nil || settings?.resolution(ToolID(cell.tool)).path == nil || !attached)
            .help("Run this code offline in the sandbox, exactly as shown")
        }
        if let statementID = cell.statementID, attached {
            Button("Edit as My Computation…") { actions?(.writeCell(statement: statementID, basedOn: message.stableID)) }
                .disabled(actions == nil)
        }
    }
}

/// How a run ended and what it printed, with Accept Refutation on a reported counterexample. What the program printed
/// is shown as printed, never typeset.
struct RunSummary: View {
    let fact: EvidenceFact
    let authors: AuthorDirectory

    @Environment(\.verificationActions) private var actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusBadge(style: StatusStyle.style(outcome: fact.outcome, verdict: fact.verdict), compact: true)
                MathText(VerificationWording.run(fact)).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let reported = VerificationWording.reported(fact) {
                Text(verbatim: reported)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(VerificationWording.runLine(fact, authors: authors))
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup("Output") {
                ToolTextBox(text: fact.output, label: "Output")
                if !fact.errorText.isEmpty { ToolTextBox(text: fact.errorText, label: "Error output") }
            }
            .font(.callout)
            if fact.canRefute {
                Button("Accept Refutation…") { actions?(.acceptRefutation(statement: fact.statementID, evidence: fact.id)) }
                    .disabled(actions == nil)
                    .help("A counterexample refutes a statement only when you accept it")
            }
        }
    }
}

/// A formalizer's draft in the thread: its note, the Lean statement and proof in full, and Check or Edit, which open a
/// sheet showing the whole module that would run.
struct LeanDraftBody: View {
    let message: Message
    let draft: LeanDraft
    let authors: AuthorDirectory

    var body: some View {
        let statement = (message.branch?.problem?.statements ?? []).first { $0.stableID == draft.statementID }
        let source = LeanSource(statementPart: draft.statementPart, proofPart: draft.proofPart)
        VStack(alignment: .leading, spacing: 8) {
            if !message.bodyLaTeX.isEmpty {
                MathText(message.bodyLaTeX).foregroundStyle(StatusStyle.style(for: .proposed).ink.color)
            }
            if let statement {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Lean code for \(statement.label)").font(.callout.weight(.medium))
                    // The standing of the checked code, when this draft is what was checked.
                    if statement.leanResult?.draftMessageID == message.stableID {
                        StatusBadge(style: StatusStyle.style(for: LeanFacts.read(statement, people: authors.personIDs).standing))
                    } else {
                        StatusBadge(style: StatusStyle.style(for: LeanStanding.notChecked), compact: true)
                    }
                }
            } else {
                Text(VerificationError.noSuchStatement.message).font(.callout).foregroundStyle(.secondary)
            }
            ToolTextBox(text: source.statementPart, label: "Lean statement")
            ToolTextBox(text: source.proofPart, label: "Lean proof")
            if let refusal = LeanGate.refusal(for: source) {
                Label("This draft cannot be checked as it is: \(refusal.message)", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(ColorToken.delicate.color)
            }
            FlowLayout(spacing: 8, lineSpacing: 6) {
                DraftActions(message: message, draft: draft)
            }
        }
    }
}

/// What a draft offers, below it and in its message's context menu alike: Check, and Edit, which starts from the
/// draft's own code even when the gate refuses it.
struct DraftActions: View {
    let message: Message
    let draft: LeanDraft

    @Environment(\.verificationActions) private var actions

    var body: some View {
        let attached = (message.branch?.problem?.statements ?? []).contains { $0.stableID == draft.statementID }
        let refused = LeanGate.refusal(for: LeanSource(statementPart: draft.statementPart, proofPart: draft.proofPart)) != nil
        if let statementID = draft.statementID, attached {
            Button("Check…") {
                actions?(.checkLean(statement: statementID, candidate: .draft(messageID: message.stableID), editing: false))
            }
            .disabled(actions == nil || refused)
            Button("Edit…") {
                actions?(.checkLean(statement: statementID, candidate: .draft(messageID: message.stableID), editing: true))
            }
            .disabled(actions == nil)
        }
    }
}

/// A cell's or a draft's context menu: its code to copy, and the same actions as beside it.
struct VerificationMessageMenu: View {
    let message: Message

    var body: some View {
        if let cell = message.computeCell {
            Button("Copy Code") { Pasteboard.copy(cell.code) }
            CellActions(message: message, cell: cell)
        } else if let draft = message.leanDraft {
            Button("Copy Lean Statement") { Pasteboard.copy(draft.statementPart) }
            Button("Copy Lean Proof") { Pasteboard.copy(draft.proofPart) }
            DraftActions(message: message, draft: draft)
        }
    }
}

/// A formalizer's or a scout's request while it runs: its output is JSON for the app, so it is not shown as it
/// arrives.
struct TaskStreamingBody: View {
    let kind: MessageKind
    let stream: MessageStream

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind == .leanDraft ? "Drafting Lean code…" : "Writing a computation…")
                .foregroundStyle(.secondary)
            StreamPhaseLabel(phase: stream.phase)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
