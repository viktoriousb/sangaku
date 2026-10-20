import SwiftData
import SwiftUI

/// Compare: two attempts with their steps paired by what they establish. A model aligns them on request; a person
/// re-pairs and judges rows and records which attempt holds. Nothing here is a check (invariant 1), and while blind
/// mode hides the authors no view below `CompareBranch` is given who wrote which attempt (invariant 9): they see only
/// what `CompareIdentity` holds.
struct CompareView: View {
    let problem: Problem
    let window: WindowState

    var body: some View {
        if let branch = window.selectedBranch(in: problem) {
            CompareBranch(problem: problem, branch: branch, window: window)
        } else {
            CompareEmptyState(window: window)
        }
    }
}

/// The attempts of one branch and the comparison of two of them, read once per render.
private struct CompareBranch: View {
    let problem: Problem
    let branch: Branch
    let window: WindowState

    @Query private var messages: [Message]
    @Query private var people: [Person]
    @Environment(\.threadManager) private var threads
    @Environment(\.alignmentService) private var alignments

    init(problem: Problem, branch: Branch, window: WindowState) {
        self.problem = problem
        self.branch = branch
        self.window = window
        let branchID = branch.stableID
        _messages = Query(filter: #Predicate<Message> { $0.branch?.stableID == branchID }, sort: \Message.createdAt)
    }

    var body: some View {
        let live = threads?.live ?? [:]
        // A fork compares the attempts it inherited as well as its own.
        let visible = branch.visibleHistory(own: messages).all
        let options = AttemptOption.make(messages: visible, live: threads?.liveMessageIDs ?? [])
        let attempts = Dictionary(visible.compactMap { message in message.proofAttempt.map { ($0.stableID, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        if let chosen = ComparePairChoice.resolve(window.compare, among: options),
           let x = attempts[chosen.0], let y = attempts[chosen.1],
           let state = alignments?.comparison(of: x, y, people: Set(people.map(\.stableID))) {
            let choice = AlignerChoice.resolve(x, y, in: problem)
            let identity = CompareIdentity.read(state, of: x, y, in: problem, windowBlind: window.blindMode,
                                                choice: choice, people: people, catalog: threads?.catalog ?? .standard)
            CompareScreen(
                problem: problem, branch: branch, window: window, state: state, options: options, chosen: chosen,
                identity: identity,
                run: CompareRunInfo.read(problem.alignment(between: x.stableID, and: y.stableID), live: live,
                                         identity: identity),
                choice: choice,
                attemptMessageIDs: [x.message?.stableID, y.message?.stableID].compactMap { $0 })
            .task(id: branch.stableID) { threads?.reconcileOrphans(in: branch) }
        } else {
            CompareEmptyState(window: window)
        }
    }
}

/// Fewer than two attempts with steps on this branch.
private struct CompareEmptyState: View {
    let window: WindowState

    var body: some View {
        ContentUnavailableView {
            Label("Nothing to compare yet", systemImage: "rectangle.split.2x1")
        } description: {
            Text("Compare sets two attempts side by side, step by step. Ask two provers in the thread; their attempts appear here once they finish.")
        } actions: {
            Button("Go to Thread") { window.activeView = .thread }
        }
    }
}

#if DEBUG
#Preview("Compare", traits: .fixture, .fixedLayout(width: 1000, height: 1000)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @State var window = WindowState()
    if let problem = problems.first {
        CompareView(problem: problem, window: window)
            .onAppear { window.select(problem: problem) }
    }
}

#Preview("Compare, dark", traits: .fixture, .fixedLayout(width: 1000, height: 1000)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @State var window = WindowState()
    if let problem = problems.first {
        CompareView(problem: problem, window: window)
            .onAppear { window.select(problem: problem) }
            .preferredColorScheme(.dark)
    }
}

#Preview("Compare, blind and narrow", traits: .fixture, .fixedLayout(width: 420, height: 1000)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @State var window = WindowState()
    if let problem = problems.first {
        CompareView(problem: problem, window: window)
            .onAppear {
                window.select(problem: problem)
                window.blindMode = true
            }
    }
}
#endif
