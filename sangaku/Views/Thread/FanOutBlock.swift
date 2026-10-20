import SwiftData
import SwiftUI

/// A fan-out under its prompt: where the attempts stand, who could see whom, the attempts side by side (stacked
/// when the column is narrow), and the referee.
struct FanOutBlock: View {
    let fanOut: FanOut
    let attempts: [Message]
    let problem: Problem
    let branch: Branch
    /// Read once by the thread and passed down.
    let live: [UUID: MessageStream]
    let run: FanOutRun?
    let notice: String?
    /// Nil when no referee has written; otherwise whether the latest one gave verdicts.
    let refereeGaveVerdicts: Bool?
    let busy: Bool
    let authors: AuthorDirectory
    let onViewContext: (RequestRecord) -> Void

    @Environment(\.threadManager) private var threads
    @Environment(\.openCompare) private var openCompare

    var body: some View {
        let agreement = FanOutAgreement.read(attempts: attempts, problem: problem, live: live, authors: authors)
        let header = FanOutHeader(
            visibility: fanOut.visibility,
            attempts: attempts.map { attempt in
                FanOutHeader.Attempt(letter: letter(of: attempt), state: FanOutHeader.AttemptState(
                    outcome: attempt.outcome(isStreaming: live[attempt.stableID] != nil),
                    queued: live[attempt.stableID]?.phase == .queued))
            },
            refereeLetter: fanOut.refereeSlotID.map { authors.letter(of: ModelSlotID($0)) },
            referee: refereeState)
        VStack(alignment: .leading, spacing: 10) {
            Text(header.title)
                .font(.callout.weight(.semibold))
            FlowLayout(spacing: 6, lineSpacing: 6) {
                NoteChip(text: header.visibilityLine,
                         systemImage: fanOut.visibility == .independent ? "eye.slash" : "eye")
                if let line = header.refereeLine {
                    NoteChip(text: line, systemImage: "person.badge.clock")
                }
            }
            EqualColumnsLayout {
                ForEach(attempts, id: \.stableID) { attempt in
                    AttemptCard(message: attempt, stream: live[attempt.stableID], authors: authors,
                                matches: agreement?.matches[attempt.stableID],
                                onViewContext: onViewContext,
                                onStop: { threads?.stop(messageID: attempt.stableID) })
                }
            }
            if let agreement, let row = agreement.divergence {
                FlowLayout(spacing: 10, lineSpacing: 6) {
                    Label(CompareWording.divergence(row), systemImage: "arrow.triangle.branch")
                        .font(.callout)
                    Button("Open Compare") { openCompare?(CompareTarget(attemptIDs: agreement.attemptIDs)) }
                        .disabled(openCompare == nil)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .statusFrame(CompareRowStyle.style(for: .diverge), cornerRadius: 8)
            }
            // On a fork made inside the fan-out, its later attempts are not on this branch: a referee here would
            // judge only some of them, so it is not offered (and a request would be refused, invariant 4).
            let hidden = (fanOut.attempts ?? []).count - attempts.count
            if hidden > 0 {
                NoteChip(text: BranchWording.hiddenAttempts(hidden), systemImage: "arrow.triangle.branch")
            } else {
                RefereeControl(fanOut: fanOut, problem: problem, branch: branch, running: run != nil,
                               refereed: refereeGaveVerdicts != nil, busy: busy, notice: notice)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(header.title)
    }

    private var refereeState: FanOutHeader.RefereeState {
        switch run?.referee {
        case .pending?: .waiting
        case .running?: .running
        default:
            switch refereeGaveVerdicts {
            case true?: .done
            case false?: .noVerdicts
            case nil: fanOut.refereeSlotID == nil ? .none : .notRun
            }
        }
    }

    private func letter(of attempt: Message) -> String {
        guard case .model(let slot) = attempt.author else { return "?" }
        return authors.letter(of: slot)
    }
}

/// What the stored comparison of a fan-out's first two attempts says in the thread: where they part ways, and the runs
/// of the later attempt's steps that match the earlier one's. Read only; nothing is requested. A step that asks for
/// attention never collapses: one the referee listed as a gap, a delicate step or a guess, or one with an open
/// objection or a re-check flag.
struct FanOutAgreement {
    /// Runs to collapse, by attempt message, with the letter of the attempt they match.
    var matches: [UUID: MatchedRuns] = [:]
    var divergence: CompareRow?
    /// The two attempts compared, for opening Compare.
    var attemptIDs: [UUID] = []

    static func read(attempts: [Message], problem: Problem, live: [UUID: MessageStream],
                     authors: AuthorDirectory) -> FanOutAgreement? {
        let finished = attempts.filter { live[$0.stableID] == nil && !($0.proofAttempt?.steps ?? []).isEmpty }
        guard finished.count >= 2, let earlier = finished[0].proofAttempt, let later = finished[1].proofAttempt,
              problem.alignment(between: earlier.stableID, and: later.stableID) != nil else { return nil }
        let people = Set(authors.profiles.keys)
        let state = ComparisonState.read(earlier, later, in: problem, people: people)
        let side: ThreadAgreement.Side = state.first.id == later.stableID ? .first : .second
        var agreement = FanOutAgreement(divergence: ThreadAgreement.firstDivergence(state.rows),
                                        attemptIDs: [earlier.stableID, later.stableID])
        let runs = ThreadAgreement.collapsedRuns(state.rows, side: side, keepOpen: flagged(later, people: people))
        if !runs.isEmpty, case .model(let slot) = finished[0].author {
            agreement.matches[finished[1].stableID] = MatchedRuns(runs: runs, other: authors.letter(of: slot))
        }
        return agreement
    }

    /// The step numbers of an attempt that must stay in view.
    private static func flagged(_ attempt: ProofAttempt, people: Set<UUID>) -> Set<Int> {
        let standing = attempt.standingVerdict
        let gaps = standing?.outcome == .gap ? Set(standing?.gapStepIndices ?? []) : []
        let standings = StepStandings.standings(of: attempt.sortedSteps, people: people)
        return gaps.union(attempt.sortedSteps.filter { step in
            let review = standings[step.stableID]
            return step.confidence == .delicate || step.confidence == .guess
                || !(review?.openObjections.isEmpty ?? true) || review?.recheck != nil
        }.map(\.index))
    }
}

/// A short note in a grey capsule, as under a fan-out's prompt.
private struct NoteChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
    }
}

/// Starts the referee by hand: after Stop all, when no referee was chosen, or to referee again. A failure to start
/// one automatically is shown here too.
private struct RefereeControl: View {
    let fanOut: FanOut
    let problem: Problem
    let branch: Branch
    let running: Bool
    let refereed: Bool
    let busy: Bool
    let notice: String?

    @Environment(\.threadManager) private var threads
    @State private var refusal: String?

    var body: some View {
        let referees = problem.sortedModelSlots.filter { $0.role == .referee }
        let chosen = referees.first { $0.stableID == fanOut.refereeSlotID }
        VStack(alignment: .leading, spacing: 4) {
            if !running {
                HStack(spacing: 8) {
                    if let chosen {
                        Button(refereed ? "Referee Again with \(chosen.letter)" : "Referee with \(chosen.letter)") {
                            start(chosen)
                        }
                    } else if !referees.isEmpty {
                        Menu(refereed ? "Referee Again With" : "Referee With") {
                            ForEach(referees) { slot in
                                Button("Model \(slot.letter)") { start(slot) }
                            }
                        }
                        .fixedSize()
                    }
                }
                .disabled(busy)
                .help(busy ? "Something is still running on this branch" : "The referee sees every attempt, partial ones marked")
            }
            if let message = refusal ?? notice.map({ "The referee could not start: \($0)" }) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(ColorToken.refuted.color)
                    .lineLimit(3)
            }
        }
    }

    private func start(_ slot: ModelSlot) {
        guard let threads else { return }
        do {
            try threads.referee(fanOut, with: slot, problem: problem, branch: branch,
                                effort: threads.draft(for: branch.stableID).effort)
            refusal = nil
        } catch {
            refusal = error.message
        }
    }
}

#if DEBUG
#Preview("Fan-out", traits: .fixture, .fixedLayout(width: 860, height: 1100)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query var people: [Person]
    @Previewable @Query var fanOuts: [FanOut]
    if let problem = problems.first, let branch = problem.sortedBranches.first, let fanOut = fanOuts.first {
        let attempts = (fanOut.attempts ?? []).compactMap(\.message).sorted { $0.createdAt < $1.createdAt }
        let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
        ScrollView {
            VStack(spacing: 24) {
                FanOutBlock(fanOut: fanOut, attempts: attempts, problem: problem, branch: branch, live: [:], run: nil,
                            notice: nil, refereeGaveVerdicts: true, busy: false, authors: authors, onViewContext: { _ in })
                // Stopped before the referee ran, with a notice; narrow, so the cards stack.
                FanOutBlock(fanOut: fanOut, attempts: attempts, problem: problem, branch: branch, live: [:], run: nil,
                            notice: "No Anthropic API key is stored.", refereeGaveVerdicts: nil, busy: false,
                            authors: authors, onViewContext: { _ in })
                    .frame(width: 300)
            }
            .padding()
        }
    }
}
#endif
