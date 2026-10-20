import AppKit
import SwiftData
import SwiftUI

/// Problems; and for the selected problem, its branches and notation registry.
struct SidebarView: View {
    let window: WindowState

    @Environment(\.problemManager) private var problems
    @Query(sort: \Problem.createdAt) private var allProblems: [Problem]
    @State private var pendingDeletion: Problem?
    @State private var confirmingDeletion = false

    var body: some View {
        @Bindable var window = window
        List(selection: $window.selectedProblemID) {
            Section("Problems") {
                ForEach(allProblems) { problem in
                    ProblemRow(problem: problem)
                        .tag(problem.stableID)
                        .contextMenu {
                            Button("Edit Problem…") { window.edit(problem) }
                            Divider()
                            Button("Delete Problem…", role: .destructive) {
                                pendingDeletion = problem
                                confirmingDeletion = true
                            }
                        }
                }
            }
            if let id = window.selectedProblemID {
                ProblemScope(id: id) { problem in
                    BranchSection(problem: problem, window: window)
                    NotationSection(problem: problem)
                }
            }
        }
        .onChange(of: window.selectedProblemID) { _, id in
            window.select(problem: problems?.problem(id: id))
        }
        .toolbar {
            ToolbarItem {
                Button("New Problem", systemImage: "plus") {
                    if let problems { window.createProblem(using: problems) }
                }
                .help("New problem (⌘N)")
            }
        }
        .confirmationDialog("Delete this problem?", isPresented: $confirmingDeletion, presenting: pendingDeletion) { problem in
            Button("Delete", role: .destructive) {
                if let problems { window.delete(problem, using: problems) }
                pendingDeletion = nil
            }
        } message: { problem in
            Text("“\(problem.title)” and its notation, branches, messages and statements will be deleted.")
        }
    }
}

private struct ProblemRow: View {
    let problem: Problem
    @Environment(\.problemManager) private var problems

    var body: some View {
        // The title renders with this problem's macros, as everywhere else the problem's math appears.
        MathText(problem.title.isEmpty ? "Untitled problem" : problem.title, showsProblems: false)
            .lineLimit(2)
            .environment(\.mathContext, problems?.mathContext(for: problem, fontSize: 13) ?? MathContext(fontSize: 13))
    }
}

/// The problem's branches with their state glyphs. Clicking one shows it in Thread, Review and Compare. The rows are
/// buttons, never tagged: the list's selection is the problem.
private struct BranchSection: View {
    let problem: Problem
    let window: WindowState

    @Environment(\.threadManager) private var threads
    @Environment(\.branchManager) private var branches
    @Environment(\.problemManager) private var problems

    var body: some View {
        // Read once, not in every row.
        let mainID = problem.mainBranchID
        let shown = window.selectedBranch(in: problem)?.stableID
        let streaming = threads?.streamingBranchIDs ?? []
        let live = threads?.liveMessageIDs ?? []
        let math = problems?.mathContext(for: problem, fontSize: 13) ?? MathContext(fontSize: 13)
        Section("Branches") {
            ForEach(problem.sortedBranches) { branch in
                BranchRow(branch: branch, isMain: branch.stableID == mainID, isShown: branch.stableID == shown,
                          offers: BranchOffers(branch, mainBranchID: mainID, streaming: streaming, live: live,
                                               hidesAuthors: window.hidesModelChrome)) { intent in
                    BranchIntentHandler.perform(intent, window: window, branches: branches)
                }
                .environment(\.mathContext, math)
            }
        }
    }
}

private struct BranchRow: View {
    let branch: Branch
    let isMain: Bool
    let isShown: Bool
    let offers: BranchOffers
    let perform: (BranchIntent) -> Void

    @Environment(\.mathRenderer) private var renderer
    @Environment(\.mathContext) private var math

    var body: some View {
        let style = StatusStyle.style(forBranch: branch.state, isMain: isMain)
        let standing = BranchWording.standing(branch.state, isMain: isMain, isRunning: offers.isRunning)
        let spoken = MathTextComposer.spoken(branch.name, renderer: renderer, context: math)
        Button { perform(.show(branchID: branch.stableID)) } label: {
            HStack(spacing: 6) {
                Text(verbatim: style.glyph)
                    .foregroundStyle(style.glyphToken.color)
                    .frame(width: 14)
                MathText(branch.name, showsProblems: false)
                    .foregroundStyle(style.ink.color)
                    .fontWeight(isShown ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if offers.isRunning {
                    Text(verbatim: StatusStyle.running.glyph)
                        .font(.caption2)
                }
                Text(standing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isShown ? "Shown in this window · \(standing)" : "Show this branch · \(standing)")
        .contextMenu {
            Button("Open Messages") { perform(.openMessages(branchID: branch.stableID)) }
            Button("Show in Branches") { perform(.showInBranches(branch.stableID)) }
            Divider()
            BranchActionItems(branchID: branch.stableID, offers: offers, perform: perform)
            if offers.hidesAuthors {
                // A menu item cannot explain why it is disabled; this line does.
                Text(BranchError.blind.message)
            }
            Divider()
            Button("Copy Branch Name") {
                Pasteboard.copy(branch.name)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(spoken), \(standing)"))
        .accessibilityAddTraits(isShown ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(named: "Show in Branches") { perform(.showInBranches(branch.stableID)) }
    }
}
