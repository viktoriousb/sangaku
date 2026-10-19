import SwiftData
import SwiftUI

/// Who the message goes to and how: a toggle per slot, visibility, the referee that follows, and how hard the
/// models think. The controls wrap rather than widen the composer, and typing never changes them.
struct RecipientControls: View {
    let problem: Problem
    @Bindable var draft: ComposerDraft

    var body: some View {
        let slots = problem.sortedModelSlots
        let resolved = draft.selection.resolved(slots.map(ProblemSnapshot.SlotDigest.init))
        let chosen = Set(resolved.provers.map(\.id.rawValue))
        let referees = slots.filter { $0.role == .referee }
        FlowLayout(spacing: 6, lineSpacing: 6) {
            Text("To").foregroundStyle(.secondary)
            if slots.isEmpty {
                Text("Model A, added on first send")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(slots) { slot in
                RecipientToggle(slot: slot, isOn: chosen.contains(slot.stableID)) { on in
                    draft.selection = draft.selection.toggling(slot.stableID, on: on, chosen: chosen)
                }
            }
            Picker("Visibility", selection: $draft.selection.visibility) {
                Text("Independent").tag(FanOutVisibility.independent)
                Text("Shared").tag(FanOutVisibility.shared)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(resolved.provers.count < 2)
            .help(resolved.visibility == .independent
                  ? "Independent: the provers write at once and never see each other's attempts"
                  : "Shared: the provers write in turn, each seeing the attempts before it")
            Picker("Referee", selection: Binding(get: { resolved.referee?.id.rawValue },
                                                 set: { draft.selection.refereeSlotID = $0 })) {
                Text("No referee").tag(UUID?.none)
                ForEach(referees) { slot in
                    Text("Then: referee with \(slot.letter)").tag(UUID?.some(slot.stableID))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(referees.isEmpty)
            .help(referees.isEmpty ? "Make a model a referee in the toolbar to have it judge the attempts"
                  : "The referee starts once every attempt has finished or been stopped, and sees them all")
            Picker("Think", selection: $draft.effort) {
                ForEach(ThinkingEffort.allCases) { Text("Think: \($0.title)").tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("How hard each model thinks before answering. More effort costs more output tokens.")
        }
    }
}

private struct RecipientToggle: View {
    let slot: ModelSlot
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        let receives = slot.role == .prover
        Toggle(isOn: Binding(get: { isOn && receives }, set: { set($0) })) {
            HStack(spacing: 4) {
                AuthorBadge(text: slot.letter, colorToken: ColorToken(rawValue: slot.colorTokenRaw))
                if isOn && receives {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                }
            }
        }
        .toggleStyle(.button)
        .disabled(!receives)
        .help(receives ? "Send to Model \(slot.letter)"
              : "Model \(slot.letter) is a \(slot.role.rawValue); only provers receive messages"
                + (slot.role == .referee ? ". Choose it as the referee instead." : "."))
        .accessibilityLabel("Model \(slot.letter), \(slot.role.rawValue)")
    }
}

/// The composer's last row: whether the context fits, the estimate, and Send or Stop. Send names its recipients
/// when there is room and shortens to "Send" when there is not, so the row never needs more than the workspace's
/// narrowest width.
struct SendBar: View {
    let plan: SendPlan?
    let streaming: Bool
    /// A fan-out runs on the branch, so Stop stops all of it, a waiting referee included.
    let stopsAll: Bool
    let canSend: Bool
    let send: () -> Void
    let stop: () -> Void

    @State private var showingDetails = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let plan {
                VStack(alignment: .leading, spacing: 3) {
                    FitLabel(plan: plan)
                    EstimateLine(plan: plan)
                }
                .layoutPriority(1)
                Button("Estimate Details", systemImage: "info.circle") { showingDetails.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("The estimate for each model")
                    .popover(isPresented: $showingDetails) { EstimateDetails(plan: plan) }
            }
            Spacer(minLength: 8)
            if streaming {
                Button(stopsAll ? "Stop All" : "Stop", systemImage: "stop.circle", action: stop)
                    .keyboardShortcut(".", modifiers: .command)
                    .fixedSize()
                    .help(stopsAll
                          ? "Stop every request on this branch; what has arrived is kept. A referee still waiting is cancelled; Referee With starts it again (⌘.)"
                          : "Stop the reply; what has arrived is kept (⌘.)")
            } else {
                let label = plan?.sendLabel ?? "Send"
                Button(action: send) {
                    ViewThatFits(in: .horizontal) {
                        Label(label, systemImage: "arrow.up.circle.fill").fixedSize()
                        Label("Send", systemImage: "arrow.up.circle.fill").fixedSize()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("\(label) (⌘↩)")
                .accessibilityLabel(label)
            }
        }
    }
}

/// Whether the context fits each model's window.
struct FitLabel: View {
    let plan: SendPlan

    var body: some View {
        Group {
            if plan.recipients.count == 1, let recipient = plan.recipients.first {
                switch recipient.fit {
                case .fits(let used, let budget)?:
                    Label("Fits \(recipient.model.displayName)'s window · ≈ \(Self.percent(used, budget)) of it",
                          systemImage: "checkmark.circle")
                case .dropped(let count, _, _)?:
                    Label("Left out \(Prose.count(count, "item")) to fit", systemImage: "scissors")
                case .unknownWindow?:
                    Label("Window unknown for \(recipient.model.displayName)", systemImage: "questionmark.circle")
                case nil:
                    EmptyView()
                }
            } else if !plan.recipients.isEmpty {
                let dropped = plan.recipients.filter { if case .dropped = $0.fit { true } else { false } }.map(\.letter)
                let unknown = plan.recipients.filter { if case .unknownWindow = $0.fit { true } else { false } }.map(\.letter)
                if !dropped.isEmpty {
                    Label("Left out items for \(Prose.list(dropped)) to fit", systemImage: "scissors")
                } else if !unknown.isEmpty {
                    Label("Window unknown for \(Prose.list(unknown))", systemImage: "questionmark.circle")
                } else if plan.recipients.allSatisfy({ $0.fit != nil }) {
                    Label("Fits every selected model's window", systemImage: "checkmark.circle")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    static func percent(_ used: Int, _ budget: Int) -> String {
        guard budget > 0 else { return "?" }
        let value = Double(used) / Double(budget) * 100
        return value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }
}

/// ≈ tokens in and the input cost, and the most the output can cost; output length is not guessed.
struct EstimateLine: View {
    let plan: SendPlan

    var body: some View {
        // Two lines are always reserved, so a changing estimate never moves Send.
        Text(Self.text(plan))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(2, reservesSpace: true)
            .help(plan.recipients.allSatisfy(\.calibrated) ? "Local estimate, corrected by the counts of earlier requests."
                  : "Local estimate; it errs high until real counts correct it.")
    }

    static func text(_ plan: SendPlan) -> String {
        var parts: [String] = []
        if let tokens = plan.recipients.first?.totalTokens {
            parts.append("≈ \(UsageFormat.tokens(tokens)) tokens in" + (plan.recipients.count > 1 ? " each" : ""))
        }
        switch plan.inputCost {
        case .range(let low, let high): parts.append("≈ \(UsageFormat.cost(low))–\(UsageFormat.cost(high)) input")
        case .single(let cost): parts.append("≈ \(UsageFormat.cost(cost)) input")
        case .unknown(let modelID): parts.append("price unknown for \(modelID.isEmpty ? "this model" : modelID)")
        }
        if let ceiling = plan.outputCeiling {
            parts.append("output at most \(UsageFormat.cost(ceiling))")
        }
        if let referee = plan.referee {
            parts.append("referee \(referee.letter)'s input once the attempts end")
        }
        return parts.joined(separator: " · ")
    }
}

/// The estimate per model, behind the composer's Details button.
struct EstimateDetails: View {
    let plan: SendPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimate before sending").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text("Input").foregroundStyle(.secondary)
                    Text("Input cost").foregroundStyle(.secondary)
                    Text("Output at most").foregroundStyle(.secondary)
                }
                ForEach(plan.recipients, id: \.letter) { recipient in
                    GridRow {
                        Text("\(recipient.letter) · \(recipient.model.displayName)")
                        Text(recipient.totalTokens.map { "≈ \(UsageFormat.tokens($0))" + (recipient.seesEarlierAttempts ? " + earlier attempts" : "") } ?? "–")
                        Text(Self.cost(recipient.cost))
                        Text(recipient.outputCeiling.map(UsageFormat.cost) ?? "price unknown")
                    }
                }
                if let referee = plan.referee {
                    GridRow {
                        Text("\(referee.letter) · \(referee.model.displayName), referee")
                        Text("once the attempts end")
                        Text("–")
                        Text(referee.outputCeiling.map(UsageFormat.cost) ?? "price unknown")
                    }
                }
            }
            .font(.callout.monospacedDigit())
            Text("Each request reserves up to \(UsageFormat.tokens(ThreadManager.maxOutputTokens)) output tokens, thinking included, so the output figure is a ceiling, not a guess. Provers that run at once each write the prompt cache: the upper input figure assumes they all do. Prices as of \(ModelCatalog.pricesAsOf).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 520)
    }

    private static func cost(_ cost: SendPlan.Cost) -> String {
        switch cost {
        case .range(let low, let high): "\(UsageFormat.cost(low))–\(UsageFormat.cost(high))"
        case .single(let value): UsageFormat.cost(value)
        case .unknown: "price unknown"
        }
    }
}

#if DEBUG
#Preview("Recipients and estimate", traits: .fixture, .fixedLayout(width: 600, height: 420)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Environment(\.threadManager) var threads
    if let problem = problems.first, let branch = problem.sortedBranches.first, let threads {
        let draft = threads.draft(for: branch.stableID)
        let slots = problem.sortedModelSlots
        let _ = draft.selection = SendSelection(recipients: Set(slots.prefix(2).map(\.stableID)),
                                                refereeSlotID: slots.last?.stableID)
        let _ = draft.text = "Prove Theorem 1."
        VStack(alignment: .leading, spacing: 16) {
            RecipientControls(problem: problem, draft: draft)
                .frame(width: 252)
            EstimateDetails(plan: threads.plan(problem: problem, branch: branch, draft: draft))
        }
        .padding()
    }
}
#endif
