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
                    BranchSection(problem: problem)
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

/// The problem's branches with their state glyphs. Read-only until Milestone 7.
private struct BranchSection: View {
    let problem: Problem

    var body: some View {
        let mainID = problem.mainBranchID
        Section("Branches") {
            ForEach(problem.sortedBranches) { branch in
                BranchRow(branch: branch, isMain: branch.stableID == mainID)
            }
        }
    }
}

private struct BranchRow: View {
    let branch: Branch
    let isMain: Bool

    var body: some View {
        let style = StatusStyle.style(for: branch.state)
        HStack(spacing: 6) {
            Text(verbatim: isMain ? "✓" : style.glyph)
                .foregroundStyle(isMain ? ColorToken.verified.color : style.ink.color)
                .frame(width: 14)
            Text(branch.name)
                .foregroundStyle(style.ink.color)
            Spacer(minLength: 4)
            Text(isMain ? "main" : style.label.lowercased())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(branch.reason ?? style.label)
        .contextMenu {
            Button("Copy Branch Name") {
                Pasteboard.copy(branch.name)
            }
            Button("Reopen Branch") {}.disabled(true).help("Branch actions arrive in Milestone 7")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(branch.name), \(isMain ? "main line" : style.label)"))
    }
}
