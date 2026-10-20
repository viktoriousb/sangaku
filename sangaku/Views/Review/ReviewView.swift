import AppKit
import SwiftData
import SwiftUI

/// Review: one attempt in reading mode, step by step. A person marks each step's current version ✓, ✗ or ?,
/// comments, dismisses objections with a reason and revises steps. Everything shown is derived from the store on
/// each render; nothing a model sends can check a step (invariant 1).
struct ReviewView: View {
    let problem: Problem
    let window: WindowState

    var body: some View {
        if let branch = window.selectedBranch(in: problem) {
            ReviewBranch(problem: problem, branch: branch, window: window)
        } else {
            ReviewEmptyState(window: window)
        }
    }
}

/// The attempts of one branch, and the one under review. It reads which attempt is chosen, not the current step,
/// so moving between steps does not derive the attempt list and the statuses again.
private struct ReviewBranch: View {
    let problem: Problem
    let branch: Branch
    let window: WindowState

    @Query private var messages: [Message]
    @Query private var people: [Person]
    @Environment(\.threadManager) private var threads
    @Environment(\.reviewManager) private var reviews
    @Environment(\.statementGraph) private var graph

    init(problem: Problem, branch: Branch, window: WindowState) {
        self.problem = problem
        self.branch = branch
        self.window = window
        let branchID = branch.stableID
        _messages = Query(filter: #Predicate<Message> { $0.branch?.stableID == branchID }, sort: \Message.createdAt)
    }

    var body: some View {
        // Read once, not in every row.
        let options = AttemptOption.make(messages: messages, live: Set((threads?.live ?? [:]).keys))
        let personIDs = Set(people.map(\.stableID))
        let graphState = graph?.state(for: problem, people: personIDs)
        let chosen = ReviewAttemptChoice.resolve(window.review, among: options,
                                                 theoremSourceAttemptID: graphState?.pinned?.sources.first?.attemptID)
        if let chosen, let reviews,
           let attempt = messages.lazy.compactMap(\.proofAttempt).first(where: { $0.stableID == chosen }) {
            ReviewScreen(attempt: attempt, state: reviews.state(of: attempt, people: personIDs), options: options,
                         graph: graphState,
                         authors: AuthorDirectory(problem: problem, people: people, catalog: threads?.catalog ?? .standard),
                         window: window)
        } else {
            ReviewEmptyState(window: window)
        }
    }
}

/// What the last action said, shown on the step it was for.
private struct ReviewNotice: Equatable {
    var stepID: UUID
    var row: ReviewRowNotice
}

private enum ReviewSheet: Identifiable {
    case revise(StepReview)
    case dismiss(StepReview, ReviewFact)

    var id: String {
        switch self {
        case .revise(let step): "revise-\(step.id)"
        case .dismiss(_, let objection): "dismiss-\(objection.id)"
        }
    }
}

/// The step list and its keyboard. One focusable container holds the steps: J, K, 1, 2, 3 and C act only while it
/// has the keyboard, never while a text field does.
private struct ReviewScreen: View {
    let attempt: ProofAttempt
    let state: AttemptReviewState
    let options: [AttemptOption]
    let graph: StatementGraphState?
    let authors: AuthorDirectory
    let window: WindowState

    @Environment(\.reviewManager) private var reviews
    @Environment(\.undoManager) private var undoManager
    @FocusState private var focus: ReviewFocus?
    @State private var position = ScrollPosition(idType: UUID.self)
    @State private var sheet: ReviewSheet?
    @State private var notice: ReviewNotice?
    /// A step whose comment field should take the keyboard once its composer is shown.
    @State private var pendingComment: UUID?
    /// Identifies this screen's actions, so they compare equal across renders.
    @State private var presenter = UUID()

    var body: some View {
        let current = state[step: window.reviewStepID]?.id
        let listHasKeyboard = focus == .list
        let highlighted = window.review.highlightedStatementID.flatMap { graph?[$0] }
        let highlightedSteps = Set(highlighted?.sources.map(\.stepID) ?? [])
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReviewHeader(theorem: graph?.pinned, options: options, chosen: state.attemptID, progress: state.progress,
                             legend: ReviewWording.legend(state, authors: authors), authors: authors,
                             highlight: highlighted?.label,
                             onChoose: { window.chooseReview(attempt: $0) },
                             onClearHighlight: { window.clearReviewHighlight() })
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(state.steps) { step in
                        ReviewStepRow(step: step, authors: authors, isCurrent: step.id == current,
                                      isActive: listHasKeyboard,
                                      highlightLabel: highlightedSteps.contains(step.id) ? highlighted?.label : nil,
                                      notice: notice?.stepID == step.id ? notice?.row : nil, focus: $focus)
                            .id(step.id)
                    }
                }
                .scrollTargetLayout()
                .padding(4)
                // With no current step, the list itself shows that it has the keyboard.
                .overlay {
                    if listHasKeyboard && current == nil {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .focusable()
                .focused($focus, equals: .list)
                .focusEffectDisabled()
                .onKeyPress(characters: ReviewKeys.characters, phases: [.down, .repeat]) { press in
                    handle(press, current: current)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Steps")
                .accessibilityRotor("Unchecked steps") {
                    ForEach(state.uncheckedStepIDs, id: \.self) { id in
                        AccessibilityRotorEntry(Text(rotorLabel(id)), id: id)
                    }
                }
                .accessibilityRotor("Delicate steps") {
                    ForEach(state.delicateStepIDs, id: \.self) { id in
                        AccessibilityRotorEntry(Text(rotorLabel(id)), id: id)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .environment(\.reviewActions, ReviewActions(presenter: presenter) { perform($0) })
        .focusedSceneValue(\.reviewControl, ReviewControl(
            presenter: presenter, attemptID: state.attemptID, currentStepID: current, hasSteps: !state.steps.isEmpty
        ) { menu($0) })
        .sheet(item: $sheet, onDismiss: { focus = .list }) { sheet in
            switch sheet {
            case .revise(let step): ReviseSheet(step: step, authors: authors)
            case .dismiss(let step, let objection): DismissSheet(step: step, objection: objection, authors: authors)
            }
        }
        .onAppear {
            focus = .list
            if let current { position.scrollTo(id: current, anchor: .top) }
        }
        .onChange(of: focus) { _, focus in
            // Typing goes on the window's undo stack too; a confirmation's Undo would then take back the wrong thing.
            if case .field = focus, notice?.row.isError == false { notice = nil }
        }
        .onChange(of: current) { _, id in
            // Without animation, so Reduce Motion needs nothing more.
            if let id { position.scrollTo(id: id) }
            // The composer of a step that just became current is in place now.
            if let id, pendingComment == id { focus = .field(id) }
            pendingComment = nil
        }
    }

    private func rotorLabel(_ id: UUID) -> String {
        guard let step = state[step: id] else { return "Step" }
        return "Step \(step.index): \(step.establishes)"
    }

    // MARK: Keys and menu

    private func handle(_ press: KeyPress, current: UUID?) -> KeyPress.Result {
        let typing = focus != .list || TextEditingProbe.isTyping(firstResponder: NSApp.keyWindow?.firstResponder)
        guard let command = ReviewKeys.command(for: ListKeyInput(press), isTyping: typing) else { return .ignored }
        run(command, in: state, current: current)
        return .handled
    }

    /// The menu reads the store afresh: its closure may be older than the latest render.
    private func menu(_ command: ReviewMenuCommand) {
        guard let reviews else { return }
        let state = reviews.state(of: attempt)
        let current = state[step: window.reviewStepID]
        switch command {
        case .command(let command):
            run(command, in: state, current: current?.id)
        case .revise:
            if let current { sheet = .revise(current) }
        }
    }

    private func run(_ command: ReviewCommand, in state: AttemptReviewState, current: UUID?) {
        switch command {
        case .next, .previous:
            guard let id = ReviewNavigation.move(command, from: current, in: state.steps.map(\.id)) else { return }
            window.focusReview(step: id)
            focus = .list
            notice = nil
        case .mark(let verdict):
            guard let step = state[step: current] else { return VoiceOver.announce("Choose a step first: J goes to the first.") }
            mark(step, verdict)
        case .comment:
            guard let step = state[step: current] else { return VoiceOver.announce("Choose a step first: J goes to the first.") }
            focus = .field(step.id)
        }
    }

    // MARK: Actions

    private func perform(_ intent: ReviewIntent) {
        switch intent {
        case .focus(let id):
            window.focusReview(step: id)
            focus = .list
        case .mark(let step, let verdict):
            window.focusReview(step: step.id)
            mark(step, verdict)
        case .withdraw(let step, let review):
            do {
                try reviews?.withdraw(review.id)
                notice = nil
                VoiceOver.announce(ReviewWording.withdrawalAnnouncement(review, step: step))
            } catch {
                fail(step, error.message)
            }
        case .undo(let step):
            // The window's undo, so the button and Edit > Undo (⌘Z) take back the same thing.
            notice = nil
            if let undoManager, undoManager.canUndo {
                undoManager.undo()
                VoiceOver.announce("Mark on step \(step.index) undone")
            }
        case .dismiss(let step, let objection):
            sheet = .dismiss(step, objection)
        case .revise(let step):
            sheet = .revise(step)
        case .comment(let step):
            if window.reviewStepID == step.id {
                focus = .field(step.id)
            } else {
                // Its composer appears once it is current; the keyboard follows then.
                pendingComment = step.id
                window.focusReview(step: step.id)
            }
        }
    }

    /// A verdict on the version the row showed; refused if the step changed since.
    private func mark(_ step: StepReview, _ verdict: ReviewVerdict) {
        guard let reviews else { return }
        guard let revision = step.standing.currentRevisionID else { return fail(step, ReviewError.noRevision.message) }
        do {
            let outcome = try reviews.mark(verdict, step: step.id, revision: revision)
            let message = ReviewWording.announcement(outcome, verdict: verdict, step: step)
            var canUndo = false
            if case .recorded(let id) = outcome, let undoManager {
                reviews.registerUndo(of: id, verdict: verdict, step: step.id, revision: revision, in: undoManager) {
                    fail(step, $0.message)
                }
                canUndo = true
            }
            notice = ReviewNotice(stepID: step.id, row: ReviewRowNotice(message: message, isError: false, canUndo: canUndo))
            VoiceOver.announce(message)
        } catch {
            fail(step, error.message)
        }
    }

    private func fail(_ step: StepReview, _ message: String) {
        notice = ReviewNotice(stepID: step.id, row: ReviewRowNotice(message: message, isError: true))
        VoiceOver.announce(message)
    }
}

/// No attempt with steps on this branch yet.
private struct ReviewEmptyState: View {
    let window: WindowState

    var body: some View {
        ContentUnavailableView {
            Label("Nothing to review yet", systemImage: "checkmark.seal")
        } description: {
            Text("Review shows a model's attempt step by step. Ask a prover in the thread; its steps appear here once it finishes.")
        } actions: {
            Button("Go to Thread") { window.activeView = .thread }
        }
    }
}

#if DEBUG
#Preview("Review", traits: .fixture, .fixedLayout(width: 760, height: 900)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @State var window = WindowState()
    if let problem = problems.first {
        ReviewView(problem: problem, window: window)
            .onAppear {
                window.select(problem: problem)
                window.reviewStepID = problem.sortedBranches.first?.sortedMessages
                    .compactMap(\.proofAttempt).first?.sortedSteps[4].stableID
            }
    }
}

#Preview("Review, nothing yet", traits: .fixedLayout(width: 640, height: 400)) {
    ReviewEmptyState(window: WindowState())
}
#endif
