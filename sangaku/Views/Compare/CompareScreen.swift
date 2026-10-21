import AppKit
import SwiftData
import SwiftUI

private enum CompareSheet: Identifiable {
    case align
    case question(QuestionDraft)
    case context(RequestRecord)

    var id: String {
        switch self {
        case .align: "align"
        case .question(let draft): "question-\(draft.id)"
        case .context(let record): "context-\(record.stableID)"
        }
    }
}

/// The comparison and its keyboard: J and K move between rows while the row list has the keyboard; the Compare menu
/// does the same from anywhere in the window.
struct CompareScreen: View {
    let problem: Problem
    let branch: Branch
    let window: WindowState
    let state: ComparisonState
    let options: [AttemptOption]
    let chosen: (UUID, UUID)
    let identity: CompareIdentity
    let run: CompareRunInfo
    let choice: AlignerChoice
    let attemptMessageIDs: [UUID]

    /// Around the content; the layout's width is the scroll view's less this on each side.
    nonisolated static let padding: CGFloat = 20

    @Environment(\.alignmentService) private var alignments
    @Environment(\.threadManager) private var threads
    @Environment(\.branchActions) private var branchActions
    @Environment(\.verificationActions) private var verificationActions
    @FocusState private var listFocused: Bool
    @State private var position = ScrollPosition(idType: RowKey.self)
    @State private var width: CGFloat = 0
    @State private var sheet: CompareSheet?
    @State private var notice: CompareNotice?
    @State private var presenter = UUID()

    var body: some View {
        let rows = state.visibleRows(window.compareFilter)
        let current = rows.first { $0.id == window.compareRow }?.id
        let mode = CompareLayoutMode.resolve(width: width)
        let context = CompareRowContext(pair: state.pair, first: state.first.steps, second: state.second.steps,
                                        firstIsPartial: state.first.isPartial, secondIsPartial: state.second.isPartial,
                                        identity: identity)
        let rowNotice = notice?.row == nil ? nil : notice
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CompareHeader(options: options, chosen: chosen, state: state, identity: identity, run: run,
                              window: window, onAlign: { sheet = .align },
                              onStop: { if let id = run.aligningRecordID { threads?.stop(messageID: id) } },
                              onViewContext: { sheet = .context($0) })
                if mode == .table {
                    HStack(spacing: 12) {
                        Text("Establishes").frame(width: CompareTableRow.labelWidth, alignment: .leading)
                        ForEach([1, 2], id: \.self) { side in
                            CompareSideHeading(side: side, identity: identity, partial: context.isPartial(side))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Alignment").frame(width: CompareTableRow.verdictWidth, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                } else {
                    ForEach([1, 2], id: \.self) { side in
                        if context.isPartial(side) {
                            CompareSideHeading(side: side, identity: identity, partial: true)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        let notice = rowNotice?.row == row.id ? rowNotice : nil
                        Group {
                            if mode == .table {
                                CompareTableRow(row: row, context: context, isCurrent: row.id == current,
                                                isActive: listFocused, notice: notice)
                            } else {
                                CompareStackedRow(row: row, context: context, isCurrent: row.id == current,
                                                  isActive: listFocused, notice: notice)
                            }
                        }
                        .id(row.id)
                    }
                    if rows.isEmpty {
                        Text("No differences: every row is judged equivalent on the current text.")
                            .foregroundStyle(.secondary)
                    }
                }
                .scrollTargetLayout()
                .padding(4)
                // With no current row, the list itself shows that it has the keyboard.
                .overlay {
                    if listFocused && current == nil {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(characters: ListKeys.characters, phases: [.down, .repeat]) { press in
                    move(press, rows: rows, current: current)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Rows")
                .accessibilityRotor("Rows that diverge") {
                    ForEach(state.divergingRowIDs, id: \.self) { AccessibilityRotorEntry(Text(rotorLabel($0)), id: $0) }
                }
                .accessibilityRotor("Rows without a match") {
                    ForEach(state.unmatchedRowIDs, id: \.self) { AccessibilityRotorEntry(Text(rotorLabel($0)), id: $0) }
                }
                .accessibilityRotor("Out-of-date rows") {
                    ForEach(state.staleRowIDs, id: \.self) { AccessibilityRotorEntry(Text(rotorLabel($0)), id: $0) }
                }
                Text(CompareKeys.legend + " · drag a step's handle onto a row of the other attempt to pair them")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                resolvePanel(rows.first { $0.id == current } ?? ThreadAgreement.firstDivergence(state.rows))
            }
            .padding(Self.padding)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width - 2 * Self.padding }, action: { width = $0 })
        }
        .scrollPosition($position)
        .environment(\.compareActions, CompareActions(presenter: presenter) { perform($0) })
        .focusedSceneValue(\.compareControl, CompareControl(
            presenter: presenter, rows: rows.map(\.id), current: current,
            canAlign: run.aligningRecordID == nil && !choice.slotIDs.isEmpty
        ) { menu($0, rows: rows.map(\.id), current: current) })
        .sheet(item: $sheet, onDismiss: { listFocused = true }) { sheet in
            switch sheet {
            case .align:
                AlignSheet(problem: problem, branch: branch, pair: state.pair, choice: choice, identity: identity,
                           rerun: state.hasModelRows)
            case .question(let draft):
                QuestionSheet(draft: draft, problem: problem, branch: branch, attemptMessageIDs: attemptMessageIDs) {
                    say("Sent to \($0). The answer arrives in the thread.", row: nil)
                }
            case .context(let record):
                RequestContextSheet(record: record)
            }
        }
        .onChange(of: current) { _, id in
            // Without animation, so Reduce Motion needs nothing more.
            if let id { position.scrollTo(id: id) }
        }
    }

    private func rotorLabel(_ key: RowKey) -> String {
        state[row: key].map(identity.label) ?? "Row"
    }

    private func move(_ press: KeyPress, rows: [CompareRow], current: RowKey?) -> KeyPress.Result {
        guard let next = ListKeys.move(ListKeyInput(press), isTyping: TextEditingProbe.typing(listHasFocus: listFocused),
                                       from: current, in: rows.map(\.id)) else { return .ignored }
        window.focusCompare(row: next)
        return .handled
    }

    /// The menu's command. `rows` and `current` are the ones `CompareControl` is compared by, so they are current.
    private func menu(_ command: CompareMenuCommand, rows: [RowKey], current: RowKey?) {
        switch command {
        case .next, .previous:
            guard let next = ListNavigation.move(forward: command == .next, from: current, in: rows) else { return }
            window.focusCompare(row: next)
            listFocused = true
        case .align:
            sheet = .align
        }
    }

    /// A row's action, on the pair the row showed.
    private func perform(_ intent: CompareIntent) {
        guard let alignments else { return }
        do throws(CompareError) {
            switch intent {
            case .focus(let key):
                window.focusCompare(row: key)
                listFocused = true
                return
            case .pair(let key, let pair):
                try alignments.pair(key, in: pair)
                window.focusCompare(row: key)
                say("Steps paired", row: key)
            case .unpair(let row, let pair):
                try alignments.unpair(row.id, in: pair)
                // The row is gone; each step now stands in a row of its own.
                say("Steps separated", row: RowKey(a: row.a?.id, b: nil))
            case .judge(let row, let verdict, let pair):
                try alignments.judge(verdict, row.id, seen: RowKey(a: row.a?.revisionID, b: row.b?.revisionID), in: pair)
                say(verdict == .equivalent ? "Marked equivalent" : "Marked diverging", row: row.id)
            case .clear(let row, let pair):
                try alignments.clearJudgement(row.id, in: pair)
                say("Your judgement cleared", row: row.id)
            }
        } catch {
            say(error.message, row: intent.row, isError: true)
        }
    }

    /// The resolve panel for a row, with Adopt and the counterexample search where they may be offered.
    private func resolvePanel(_ row: CompareRow?) -> some View {
        let adoption: CompareAdoption = branchActions == nil ? .none
            : CompareAdoption.offer(identity: identity, pair: state.pair, adopted: problem.adoptedAttemptID)
        return ResolvePanel(row: row, identity: identity, run: run, notice: notice?.row == nil ? notice : nil,
                            adoption: adoption, onHolds: { record($0, in: state.pair) }, onAsk: { sheet = .question($0) },
                            onAdopt: { branchActions?(.adopt(attemptID: $0)) },
                            counterexample: row.map { CompareSearch.seed($0, problem: problem) },
                            onSearch: verificationActions == nil ? nil : search, searchWaits: window.hidesModelChrome)
    }

    private func search(_ seed: ScoutSeed) {
        verificationActions?(.askForCheck(seed))
    }

    private func record(_ verdict: HoldsVerdict, in pair: ComparedPair) {
        do {
            try alignments?.recordHolds(verdict, in: pair)
            say("Recorded: \(CompareWording.holds(verdict))", row: nil)
        } catch {
            say(error.message, row: nil, isError: true)
        }
    }

    /// Shows what came of an action beside where it was taken, and says it to VoiceOver.
    private func say(_ text: String, row: RowKey?, isError: Bool = false) {
        notice = CompareNotice(row: row, text: text, isError: isError)
        VoiceOver.announce(text)
    }
}
