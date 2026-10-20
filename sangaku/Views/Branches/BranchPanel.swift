import SwiftData
import SwiftUI

/// The selected node's panel. For a branch: where it stands and came from, why it died (written by people), the exact
/// text models are sent with the In Context toggle, and what can be done with it now. For an attempt: what it has
/// earned and Adopt. For a salvaged lemma: where it came from.
struct BranchPanel: View {
    let problem: Problem
    let node: BranchTree.Node
    let tree: BranchTree
    let window: WindowState
    let authors: AuthorDirectory
    let offers: BranchOffers?

    @Environment(\.branchActions) private var actions
    @Environment(\.branchManager) private var branches
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusBadge(style: BranchWording.style(node))
                MathText(BranchWording.title(node), showsProblems: false)
                    .font(.headline)
                if node.branch?.isRunning == true {
                    StatusBadge(style: .running)
                }
            }
            Text(BranchWording.caption(node))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch node.kind {
            case .branch(let facts):
                if let branch = problem.sortedBranches.first(where: { $0.stableID == facts.id }) {
                    branchDetail(branch, facts: facts)
                }
            case .attempt(let attempt):
                attemptDetail(attempt)
            case .lemma(let lemma):
                lemmaDetail(lemma)
            case .problem:
                problemDetail
            }
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(ColorToken.refuted.color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .onChange(of: node.id) { notice = nil }
    }

    // MARK: Branch

    @ViewBuilder private func branchDetail(_ branch: Branch, facts: BranchTree.BranchFacts) -> some View {
        Text(BranchWording.explored(by: facts.authors, from: facts.firstMessageAt, to: facts.lastMessageAt,
                                    messages: facts.ownMessages))
            .font(.caption)
            .foregroundStyle(.secondary)
        if let fork = branch.forkedFrom, let parent = fork.branch {
            MathText(BranchWording.forkLine(kind: fork.kind, author: authors.name(of: fork.author), branch: parent.name),
                     showsProblems: false)
                .font(.callout)
            Text(BranchWording.inherited(facts.inheritedMessages))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let fault = branch.visibleHistory.fault {
            Label(fault.message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(ColorToken.refuted.color)
        }
        if facts.isMain, let adopted = adoptedAttempt, adopted.branchID == facts.id {
            Text(BranchWording.adoption(attempt: "\(adopted.author)'s attempt", by: adoptedBy, at: problem.adoptedAt))
                .font(.callout)
            adoptionNotes(adopted)
        }
        if branch.state.isClosed || branch.reason != nil {
            reasons(branch)
        }
        branchActions(facts)
    }

    @ViewBuilder private func reasons(_ branch: Branch) -> some View {
        Divider()
        Text(branch.state == .parked ? "Note" : "Why it died").font(.callout.weight(.semibold))
        if let reason = BranchReasons.trimmed(branch.reason) {
            MathText(reason)
                .textSelection(.enabled)
        } else {
            Text("No reason written yet.").foregroundStyle(.secondary)
        }
        if let line = BranchWording.provenance(by: person(branch.reasonByID), from: message(branch.reasonFromMessageID)) {
            Text(line).font(.caption).foregroundStyle(.secondary)
        }
        if branch.state == .deadEnd {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sent to models as").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("In Context", isOn: Binding(get: { branch.includeReasonInContext }, set: { on in
                        do throws(BranchError) {
                            try branches?.setInContext(on, for: branch)
                            notice = nil
                        } catch {
                            notice = error.message
                            VoiceOver.announce(error.message)
                        }
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                Text(ContextBuilder.deadEndLine(.init(branch)))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(branch.includeReasonInContext ? .primary : .secondary)
                Text(BranchWording.sent(state: branch.state, inContext: branch.includeReasonInContext))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let line = BranchWording.provenance(by: person(branch.modelTextByID),
                                                       from: message(branch.modelTextFromMessageID)) {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
        } else {
            Text(BranchWording.sent(state: branch.state, inContext: false))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The same actions as the node's menu and the sidebar's, from `BranchOffers`, with why any is disabled.
    @ViewBuilder private func branchActions(_ facts: BranchTree.BranchFacts) -> some View {
        Divider()
        FlowLayout(spacing: 8, lineSpacing: 6) {
            Button("Open Messages") { actions?(.openMessages(branchID: facts.id)) }
            if let offers {
                BranchActionItems(branchID: facts.id, offers: offers) { actions?($0) }
            }
        }
        .disabled(actions == nil)
        if let offers {
            BranchRefusals(offers: offers)
        }
    }

    /// What adopting did not do, and whether the proof it adopted stopped short.
    @ViewBuilder private func adoptionNotes(_ adopted: BranchTree.AttemptFacts) -> some View {
        if adopted.isPartial {
            Label(BranchWording.partialProof, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(BranchWording.adoptChecksNothing)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Attempt, lemma, problem

    /// The caption above already says what the attempt has earned and what the referee said.
    @ViewBuilder private func attemptDetail(_ attempt: BranchTree.AttemptFacts) -> some View {
        if attempt.isAdopted {
            Label("The main line's proof. \(BranchWording.adoptChecksNothing)", systemImage: "diamond.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        FlowLayout(spacing: 8, lineSpacing: 6) {
            if !attempt.isAdopted {
                Button(BranchWording.adoptTitle(attempt.author)) { actions?(.adopt(attemptID: attempt.id)) }
                    .disabled(actions == nil)
                    .help(BranchWording.adoptHelp)
            }
            Button("Review Step by Step") {
                window.switchBranch(to: attempt.branchID)
                window.openReview(ReviewTarget(attemptIDs: [attempt.id]))
            }
            Button("Cherry-pick a Step…") { window.branchSheet = .cherryPick(PromotionTarget(attemptIDs: [attempt.id])) }
                .help("Make steps of this attempt a lemma")
            Button("Open Messages") { actions?(.openMessages(branchID: attempt.branchID)) }
                .disabled(actions == nil)
        }
    }

    @ViewBuilder private func lemmaDetail(_ lemma: BranchTree.LemmaFacts) -> some View {
        if let attempt = tree[lemma.attemptID]?.attempt, let branch = tree[attempt.branchID]?.branch {
            MathText(BranchWording.salvaged(author: attempt.author, branch: branch.name), showsProblems: false)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button("Show in Proof Structure") { actions?(.revealStatement(lemma.id)) }
            .disabled(actions == nil)
    }

    @ViewBuilder private var problemDetail: some View {
        if let adopted = adoptedAttempt, let branch = tree[adopted.branchID]?.branch {
            MathText(BranchWording.adoption(attempt: "\(adopted.author)'s attempt on \(branch.name)", by: adoptedBy,
                                            at: problem.adoptedAt), showsProblems: false)
                .font(.callout)
            adoptionNotes(adopted)
        } else {
            Text("No attempt is adopted yet. Adopt one from the referee's message, from Compare, or from an attempt here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("Select a branch to see why it died, what models are sent, and what can be done with it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    private var adoptedAttempt: BranchTree.AttemptFacts? { tree[problem.adoptedAttemptID]?.attempt }

    private var adoptedBy: String? { person(problem.adoptedByID) }

    /// A person's name; nil for an ID that is no person, so a model can never be shown as having written a reason.
    private func person(_ id: UUID?) -> String? {
        guard let id, authors.profiles[id] != nil else { return nil }
        return authors.name(ofPerson: id)
    }

    /// "Model A's reply": the message a text was started from.
    private func message(_ id: UUID?) -> String? {
        guard let id else { return nil }
        for branch in problem.sortedBranches {
            if let message = (branch.messages ?? []).first(where: { $0.stableID == id }) {
                return BranchWording.message(kind: message.kind, author: authors.name(of: message.author))
            }
        }
        return nil
    }
}

/// What every new prompt on the problem carries, whichever branch it is sent on, in the very lines that are sent.
struct PromptCarriesCard: View {
    let carries: PromptCarries

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What every new prompt carries").font(.headline)
            row("Problem") { MathText(carries.problemTitle.isEmpty ? "Untitled problem" : carries.problemTitle, showsProblems: false) }
            row("Notation") { Text(Prose.count(carries.notationCount, "entry", plural: "entries")) }
            lines("Lemmas", carries.lemmas, none: "No lemma is adopted yet.")
            lines("Dead ends", carries.deadEnds, none: "No dead end is in context.")
            lines("Refuted claims", carries.refuted, none: "None.")
            Text(PromptCarries.dropNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content().font(.callout)
        }
    }

    private func lines(_ title: String, _ items: [PromptCarries.Item], none: String) -> some View {
        row(title) {
            if items.isEmpty {
                Text(none).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        Text(item.line)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

#if DEBUG
/// One node's panel from the fixture's tree, read as the Branches screen reads it.
private struct BranchPanelPreview: View {
    let pick: (BranchTree) -> UUID?

    @Query private var problems: [Problem]
    @Query private var people: [Person]
    @Environment(\.statementGraph) private var graph
    @State private var window = WindowState()

    var body: some View {
        if let problem = problems.first {
            let personIDs = Set(people.map(\.stableID))
            let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
            let tree = BranchTree.read(problem: problem, graph: graph?.state(for: problem, people: personIDs) ?? .empty,
                                       people: personIDs, authors: authors, running: [], live: [], showsDeadEnds: true)
            if let node = tree[pick(tree)] {
                BranchPanel(problem: problem, node: node, tree: tree, window: window, authors: authors,
                            offers: node.branch?.offers)
                    .branchSheets(problem: problem, window: window)
                    .frame(width: BranchesLayoutMode.panelWidth)
                    .padding()
            }
        }
    }
}

#Preview("Panel, dead end", traits: .fixture, .sizeThatFitsLayout) {
    BranchPanelPreview { $0.deadEndIDs.first }
}

#Preview("Panel, main line", traits: .fixture, .sizeThatFitsLayout) {
    BranchPanelPreview { tree in tree.nodes.first { $0.branch?.isMain == true }?.id }
}

#Preview("Panel, attempt", traits: .fixture, .sizeThatFitsLayout) {
    BranchPanelPreview { $0.attemptIDs.last }
}

#Preview("Panel, salvaged lemma, dark", traits: .salvagedFixture, .sizeThatFitsLayout) {
    BranchPanelPreview { tree in tree.nodes.first { $0.lemma != nil }?.id }
        .preferredColorScheme(.dark)
}

#Preview("What every prompt carries", traits: .fixture, .sizeThatFitsLayout) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query var people: [Person]
    @Previewable @Environment(\.problemManager) var manager
    if let problem = problems.first, let manager {
        PromptCarriesCard(carries: PromptCarries(ProblemSnapshot.stable(
            problem: problem, notation: manager.notation(for: problem), people: people)))
            .frame(width: BranchesLayoutMode.panelWidth)
            .padding()
    }
}
#endif
