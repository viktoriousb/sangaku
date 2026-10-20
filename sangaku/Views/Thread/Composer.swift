import SwiftData
import SwiftUI

/// Writes to the problem's models: who receives the message and how, LaTeX source with a live preview, what the
/// context will carry and whether it fits, an estimated cost per model, and Send (⌘↩) or Stop (⌘.). The draft
/// lives in `ThreadManager`, so it survives switching views.
struct Composer: View {
    let problem: Problem
    let branch: Branch
    /// Seeds the estimate, for previews and layout tests; the composer makes its own as soon as it appears.
    var plan: SendPlan?

    @Environment(\.threadManager) private var threads

    var body: some View {
        if let threads {
            // One composer per branch: its estimate and messages never carry over to another branch.
            ComposerContent(problem: problem, branch: branch, threads: threads,
                            draft: threads.draft(for: branch.stableID), initialPlan: plan)
                .id(branch.stableID)
        } else {
            Label("Sending is unavailable in this window.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(ColorToken.refuted.color)
        }
    }
}

private struct ComposerContent: View {
    let problem: Problem
    let branch: Branch
    let threads: ThreadManager
    @Bindable var draft: ComposerDraft

    @Environment(\.problemManager) private var problems
    @Environment(\.credentialManager) private var credentials
    @Environment(\.mathContext) private var mathContext
    @Query private var messages: [Message]

    @State private var plan: SendPlan?
    @State private var refusal: SendBlocker?
    @State private var showingDropped = false

    init(problem: Problem, branch: Branch, threads: ThreadManager, draft: ComposerDraft, initialPlan: SendPlan?) {
        self.problem = problem
        self.branch = branch
        self.threads = threads
        self.draft = draft
        _plan = State(initialValue: initialPlan)
        let branchID = branch.stableID
        _messages = Query(filter: #Predicate<Message> { $0.branch?.stableID == branchID })
    }

    /// Fixed heights, so typing never moves the composer or pushes Send out of the window: the editor and the
    /// preview scroll inside them.
    static let editorHeight: CGFloat = 68
    static let previewHeight: CGFloat = 54

    var body: some View {
        let providerID = plan?.providerID ?? threads.defaultProviderID
        let keyState = credentials?.state(for: providerID) ?? .unknown
        let streaming = threads.streamingBranchIDs.contains(branch.stableID)
        let allowed = problems?.allows(providerID, for: problem) ?? false
        VStack(alignment: .leading, spacing: 8) {
            RecipientControls(problem: problem, draft: draft)

            if !allowed {
                PolicyBanner(providerName: plan?.providerName ?? providerID) {
                    problems?.setProvider(providerID, allowed: true, for: problem)
                }
            } else if keyState == .missing {
                Banner(systemImage: "key", text: "No \(plan?.providerName ?? providerID) API key is stored.") {
                    SettingsLink { Text("Open Settings…") }
                }
            } else if case .unavailable(let message) = keyState {
                Banner(systemImage: "exclamationmark.triangle", text: "The keychain could not be read: \(message)") {
                    SettingsLink { Text("Open Settings…") }
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .accessibilityLabel("Message, LaTeX source")
                if draft.text.isEmpty {
                    Text("Message · LaTeX, with $…$ inline and $$…$$ display")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: Self.editorHeight)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }

            PreviewStrip(text: draft.text, macros: mathContext.macros)
                .frame(height: Self.previewHeight)

            if let plan, allowed {
                ContextChips(plan: plan, showingDropped: $showingDropped)
            }

            SendBar(plan: allowed ? plan : nil, streaming: streaming,
                    stopsAll: threads.runs.values.contains { $0.branchID == branch.stableID },
                    canSend: !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && allowed
                        && keyState != .missing,
                    send: send, stop: { threads.stop(branchID: branch.stableID) })

            if let blocker = refusal ?? plan?.blocker, Self.showsInline(blocker) {
                Label(blocker.message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(ColorToken.refuted.color)
            }
        }
        .padding(14)
        .background(.bar, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator) }
        .task(id: PlanKey(problemID: problem.stableID, branchID: branch.stableID, text: draft.text,
                          effort: draft.effort, selection: draft.selection, messages: messages.count, allowed: allowed,
                          keyState: keyState, streaming: streaming,
                          context: problems?.contextRevisions[problem.stableID] ?? 0,
                          notation: problems?.notationRevisions[problem.stableID] ?? 0)) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            plan = threads.plan(problem: problem, branch: branch, draft: draft)
        }
        // Whether a key is stored is checked when the composer appears, so its banner never appears mid-typing.
        // The check asks for attributes only: it never reads the key and never shows a Keychain prompt.
        .task {
            guard let credentials, credentials.state(for: providerID) == .unknown else { return }
            await credentials.refresh(providerID)
        }
        .onChange(of: draft.text) { refusal = nil }
    }

    private func send() {
        do {
            try threads.send(problem: problem, branch: branch, draft: draft)
            refusal = nil
        } catch {
            refusal = error
        }
    }

    /// Blockers with their own banner or control (policy, key, Stop, an empty editor) are not repeated.
    private static func showsInline(_ blocker: SendBlocker) -> Bool {
        switch blocker {
        case .emptyMessage, .busy, .providerNotAllowed, .missingKey: false
        case .noRolePrompt, .noProvider, .context, .noProver, .slotCannotReceive, .recipient, .slotMissing, .compare: true
        }
    }
}

/// The typeset draft, in a fixed height that scrolls to its end as the draft grows. Always shown, so the first
/// keystroke does not make the composer jump.
private struct PreviewStrip: View {
    let text: String
    let macros: MacroSet

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("PREVIEW")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ScrollView {
                Group {
                    if text.isEmpty {
                        Text("The typeset message appears here.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    } else {
                        MathText(text)
                            .environment(\.mathContext, MathContext(macros: macros, fontSize: 15))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
        .padding(8)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 6))
    }
}

private struct PlanKey: Hashable {
    var problemID: UUID
    var branchID: UUID
    var text: String
    var effort: ThinkingEffort
    var selection: SendSelection
    var messages: Int
    var allowed: Bool
    var keyState: CredentialManager.KeyState
    var streaming: Bool
    var context: Int
    var notation: Int
}

private struct PolicyBanner: View {
    let providerName: String
    let allow: () -> Void

    var body: some View {
        Banner(systemImage: "lock", text: "This problem does not allow \(providerName). Nothing about it is sent until you allow it.") {
            Button("Allow \(providerName) for This Problem", action: allow)
        }
    }
}

private struct Banner<Action: View>: View {
    let systemImage: String
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        // On one line when it fits; otherwise the action goes under the text, so a narrow column never clips it.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                message
                Spacer(minLength: 8)
                action()
            }
            VStack(alignment: .leading, spacing: 6) {
                message
                action()
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the context carries, and whether it fits the model's window.
private struct ContextChips: View {
    let plan: SendPlan
    @Binding var showingDropped: Bool

    var body: some View {
        let sections = plan.sections.filter { $0.kind != .rolePrompt }
        let titles = sections.map(Self.chipTitle) + ["Conversation (\(plan.conversationMessages))"]
        // One line: the chips when they fit, else the same list as one line of text, so the composer never grows
        // taller in a narrow column.
        HStack(spacing: 6) {
            Text("Context").font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(sections, id: \.kind) { section in
                        Chip(text: Self.chipTitle(section),
                             help: "\(section.title): ≈ \(UsageFormat.tokens(section.tokens)) tokens before calibration")
                    }
                    Chip(text: "Conversation (\(plan.conversationMessages))", help: "Earlier messages on this branch")
                }
                Text(titles.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(titles.joined(separator: "\n"))
                    .accessibilityLabel("Context: " + titles.joined(separator: ", "))
            }
            if !plan.dropped.isEmpty {
                Button("\(plan.dropped.count) left out", systemImage: "scissors") { showingDropped.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .fixedSize()
                    .popover(isPresented: $showingDropped) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Left out to fit the window").font(.headline)
                            ForEach(Array(plan.dropped.enumerated()), id: \.offset) { _, item in
                                Text("\(item.kind): \(item.title)").font(.callout)
                            }
                        }
                        .padding()
                    }
            }
        }
    }

    private static func chipTitle(_ section: ContextSection) -> String {
        switch section.kind {
        case .rolePrompt, .problem: section.title
        case .notation: "Notation (\(section.itemCount))"
        case .adoptedLemmas: "Lemmas (\(section.itemCount))"
        case .deadEnds: "Dead ends (\(section.itemCount))"
        case .refutedClaims: "Refuted (\(section.itemCount))"
        }
    }
}

private struct Chip: View {
    let text: String
    let help: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
            .fixedSize()
            .help(help)
    }
}

#if DEBUG
#Preview("Composer", traits: .fixture, .fixedLayout(width: 860, height: 360)) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first, let branch = problem.sortedBranches.first {
        Composer(problem: problem, branch: branch)
            .padding()
    }
}
#endif
