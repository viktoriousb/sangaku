import SwiftData
import SwiftUI

/// The thread for the selected problem and branch: the pinned problem, the messages, and the composer.
struct ThreadView: View {
    let problem: Problem
    let window: WindowState

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var promotion: PromotionTarget?
    /// Identifies this thread's promote action, so it compares equal across renders.
    @State private var presenter = UUID()

    var body: some View {
        let branch = window.selectedBranch(in: problem)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PinnedProblemCard(problem: problem) { window.edit(problem) }
                if let branch {
                    BranchMessages(problem: problem, branch: branch) { position.scrollTo(edge: .bottom) }
                }
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
            .environment(\.promoteSteps, PromoteStepsAction(presenter: presenter) { promotion = $0 })
            .environment(\.openReview, OpenReviewAction(presenter: presenter) { window.openReview($0) })
            .environment(\.openCompare, OpenCompareAction(presenter: presenter) { window.openCompare($0) })
        }
        .sheet(item: $promotion) { target in
            // The new statement is shown, selected, in the proof-structure inspector.
            PromoteSheet(problem: problem, target: target) { window.reveal(statement: $0) }
        }
        .scrollPosition($position)
        // A reply that grows keeps the end of the thread in view.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let branch {
                // Never narrower than the workspace's minimum: AppKit sizes the column from the composer's
                // height at the smallest width it is offered, and at zero width its text would wrap a character
                // per line and push the column, and Send, past the bottom of the window.
                Composer(problem: problem, branch: branch)
                    .frame(minWidth: WindowRoot.contentMinWidth - 48, maxWidth: 860)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The messages of one branch as models on it see them (`Branch.visibleHistory`): a fork's inherited messages, a
/// divider where it was forked, then its own, oldest first.
private struct BranchMessages: View {
    let problem: Problem
    let branch: Branch
    /// Called when a message is added or a reply finishes, to bring the end of the thread into view.
    let onNewMessage: () -> Void

    @Query private var messages: [Message]
    @Query private var people: [Person]
    @Environment(\.threadManager) private var threads
    @State private var contextRecord: RequestRecord?

    init(problem: Problem, branch: Branch, onNewMessage: @escaping () -> Void) {
        self.problem = problem
        self.branch = branch
        self.onNewMessage = onNewMessage
        let branchID = branch.stableID
        _messages = Query(filter: #Predicate<Message> { $0.branch?.stableID == branchID }, sort: \Message.createdAt)
    }

    var body: some View {
        // Read once, not in every row.
        let live = threads?.live ?? [:]
        let history = branch.visibleHistory(own: messages)
        let items = ThreadItem.make(history.all)
        let inherited = history.inheritedIDs
        let authors = AuthorDirectory(problem: problem, people: people, catalog: threads?.catalog ?? .standard)
        let context = ThreadContext(
            problem: problem, branch: branch, items: items, messages: history.all, live: live,
            runs: threads?.runs ?? [:], notices: threads?.refereeNotices ?? [:], authors: authors,
            busy: threads?.streamingBranchIDs.contains(branch.stableID) ?? true)
        // The divider goes before the first item of the branch's own, or after everything when it has none yet.
        let firstOwn = items.first { !inherited.contains($0.id) }?.id
        LazyVStack(alignment: .leading, spacing: 14) {
            BranchHeader(problem: problem, branch: branch, history: history, authors: authors)
            if history.all.isEmpty {
                Text(BranchWording.noMessage)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(items) { item in
                if !inherited.isEmpty, item.id == firstOwn { ForkDivider(branch: branch) }
                ThreadItemView(item: item, context: context, onViewContext: { contextRecord = $0 })
            }
            if !inherited.isEmpty, firstOwn == nil { ForkDivider(branch: branch) }
        }
        .sheet(item: $contextRecord) { record in
            RequestContextSheet(record: record)
        }
        .task(id: branch.stableID) {
            threads?.reconcileOrphans(in: branch)
        }
        .onChange(of: messages.count) { onNewMessage() }
        .id(branch.stableID)
        // A reply that finished may have grown past the end while it streamed.
        .onChange(of: live.count) { onNewMessage() }
    }
}

#if DEBUG
#Preview("Thread", traits: .fixture, .fixedLayout(width: 900, height: 900)) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first {
        ThreadView(problem: problem, window: WindowState())
    }
}
#endif
