import SwiftUI

/// The resolve panel for the current row: the blind verdict, and the requests that act on a disagreement.
struct ResolvePanel: View {
    let row: CompareRow?
    let identity: CompareIdentity
    let run: CompareRunInfo
    /// What came of the last verdict or request made here.
    var notice: CompareNotice?
    let onHolds: @MainActor (HoldsVerdict) -> Void
    let onAsk: @MainActor (QuestionDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resolve").font(.headline)
            verdict
            Divider()
            if identity.hidden {
                Text("Asking a model about a row names the models. Record which attempt holds first, or turn blind mode off.")
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
            FlowLayout(spacing: 8, lineSpacing: 6) {
                Button("Adopt an Attempt") {}
                    .disabled(true)
                Button("Search for a Counterexample") {}
                    .disabled(true)
            }
            Text("Adopting an attempt as the main line arrives with Milestone 7; counterexample searches with Milestone 8.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
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
