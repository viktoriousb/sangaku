import SwiftUI

/// The resolve panel for the current row: the blind verdict, the requests that act on a disagreement, and adopting
/// an attempt as the main line.
struct ResolvePanel: View {
    let row: CompareRow?
    let identity: CompareIdentity
    let run: CompareRunInfo
    /// What came of the last verdict or request made here.
    var notice: CompareNotice?
    var adoption: CompareAdoption = .none
    let onHolds: @MainActor (HoldsVerdict) -> Void
    let onAsk: @MainActor (QuestionDraft) -> Void
    var onAdopt: @MainActor (UUID) -> Void = { _ in }
    /// A scout's search on the row shown, and how to ask for it; nil where none can be asked.
    var counterexample: ScoutSeed?
    var onSearch: (@MainActor (ScoutSeed) -> Void)?
    /// Blind mode is on: asking a scout waits until it is off, even after a verdict (invariant 9).
    var searchWaits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resolve").font(.headline)
            verdict
            Divider()
            if identity.hidden {
                Text(CompareWording.askWhileBlind)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let row {
                requests(for: row)
            } else {
                Text("Choose a row to ask about it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(notice.isError ? ColorToken.refuted.color : .secondary)
            }
            Divider()
            adopt
            search
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    /// Adopting one attempt as the main line; while blind it waits, in words a keyboard user sees too.
    @ViewBuilder private var adopt: some View {
        switch adoption {
        case .none:
            EmptyView()
        case .waitingForVerdict:
            Button("Adopt an Attempt") {}
                .disabled(true)
            Text(CompareAdoption.blindCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .choices(let choices):
            FlowLayout(spacing: 8, lineSpacing: 6) {
                ForEach(choices) { choice in
                    if choice.isAdopted {
                        Label(BranchWording.isMainProof(CompareWording.attempt(choice.side)), systemImage: "diamond.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(choice.title) { onAdopt(choice.attemptID) }
                            .help(BranchWording.adoptHelp)
                    }
                }
            }
        }
    }

    @ViewBuilder private var verdict: some View {
        if run.holdsRecorded {
            Text(CompareWording.recorded(run.holds, at: run.holdsAt))
                .font(.callout.weight(.medium))
            Text("Your verdict is kept with this comparison. It changes no check or status.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Which attempt holds up?")
                .font(.callout.weight(.medium))
            FlowLayout(spacing: 8, lineSpacing: 6) {
                ForEach(HoldsVerdict.allCases, id: \.self) { verdict in
                    Button(CompareWording.holds(verdict)) { onHolds(verdict) }
                }
            }
            Text(identity.hidden ? "Recording it reveals who wrote each attempt. It changes no check or status."
                                 : "Your verdict is kept with this comparison. It changes no check or status.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A counterexample search asks a scout, whose sheet shows which models there are, so while blind mode is on it
    /// waits, in words a keyboard user sees too (invariant 9).
    @ViewBuilder private var search: some View {
        if identity.hidden || searchWaits {
            Text(VerificationWording.waitsWhileBlind)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let counterexample, let onSearch {
            Button("Search for a Counterexample…") { onSearch(counterexample) }
                .help("Ask a scout for a computation that tests this row's claims")
            Text("A scout writes the computation; it runs only when you click Run on its code.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Choose a row to search it for a counterexample.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func requests(for row: CompareRow) -> some View {
        FlowLayout(spacing: 8, lineSpacing: 6) {
            ForEach([1, 2], id: \.self) { side in
                if let slot = side == 1 ? identity.firstSlotID : identity.secondSlotID,
                   let step = side == 1 ? row.a : row.b,
                   let text = CompareWording.repairRequest(row, side: side, identity: identity),
                   let name = identity.mark(side)?.name {
                    Button("Ask \(name) to Repair Step \(step.index)…") {
                        onAsk(QuestionDraft(title: "Ask \(name) to repair step \(step.index)", text: text, slotID: slot,
                                            recipient: name))
                    }
                }
            }
            if let referee = identity.referee {
                Button("Send This Row to \(referee.name)…") {
                    onAsk(QuestionDraft(title: "Send this row to \(referee.name)",
                                        text: CompareWording.refereeRequest(row, identity: identity), slotID: referee.id,
                                        recipient: referee.name))
                }
            }
        }
        Text("The answer arrives in the thread. Nothing changes a step until you revise it.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
