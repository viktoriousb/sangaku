import SwiftData
import SwiftUI

/// Which branch the thread shows: its name and standing, and for a fork where it came from and what it inherits.
struct BranchHeader: View {
    let problem: Problem
    let branch: Branch
    let history: VisibleHistory
    let authors: AuthorDirectory

    @Environment(\.branchActions) private var actions
    @Environment(\.threadManager) private var threads
    @Environment(\.mathRenderer) private var renderer
    @Environment(\.mathContext) private var math

    var body: some View {
        let isMain = problem.mainBranchID == branch.stableID
        let running = threads?.streamingBranchIDs.contains(branch.stableID) ?? false
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 8, lineSpacing: 4) {
                StatusBadge(style: StatusStyle.style(forBranch: branch.state, isMain: isMain), compact: true)
                MathText(branch.name, showsProblems: false)
                    .font(.callout.weight(.semibold))
                Text(BranchWording.standing(branch.state, isMain: isMain, isRunning: running))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if running {
                    StatusBadge(style: .running, compact: true)
                }
                Button("Show in Branches") { actions?(.showInBranches(branch.stableID)) }
                    .buttonStyle(.link)
                    .font(.callout)
                    .disabled(actions == nil)
            }
            if let fork = branch.forkedFrom, let parent = fork.branch {
                FlowLayout(spacing: 8, lineSpacing: 4) {
                    MathText(BranchWording.forkLine(kind: fork.kind, author: authors.name(of: fork.author),
                                                    branch: parent.name), showsProblems: false)
                    Button { actions?(.openMessages(branchID: parent.stableID)) } label: {
                        MathText("Show " + parent.name, showsProblems: false)
                    }
                    .buttonStyle(.link)
                    .disabled(actions == nil)
                    .accessibilityLabel("Show " + MathTextComposer.spoken(parent.name, renderer: renderer, context: math))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let fault = history.fault {
                Label(fault.message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(ColorToken.refuted.color)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branch " + MathTextComposer.spoken(branch.name, renderer: renderer, context: math))
    }
}

/// Where a fork begins: above it the parent's messages, below it the branch's own.
struct ForkDivider: View {
    let branch: Branch

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 1)
            MathText("Forked here: \(branch.name) continues below", showsProblems: false)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .layoutPriority(1)
            Rectangle().fill(.separator).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Header and fork divider", traits: .fixture, .sizeThatFitsLayout) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query var people: [Person]
    if let problem = problems.first {
        let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
        VStack(alignment: .leading, spacing: 16) {
            ForEach(problem.sortedBranches, id: \.stableID) { branch in
                BranchHeader(problem: problem, branch: branch, history: branch.visibleHistory, authors: authors)
                if branch.forkedFrom != nil {
                    ForkDivider(branch: branch)
                }
            }
        }
        .frame(width: 560)
        .padding()
    }
}
#endif
