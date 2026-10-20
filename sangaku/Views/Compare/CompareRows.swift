import SwiftData
import SwiftUI

/// What a row needs besides itself: the pair it belongs to, the two attempts' steps (for "Pair with…"), whether each
/// attempt stopped early, and who wrote each side as Compare may show it.
struct CompareRowContext: Equatable {
    let pair: ComparedPair
    let first: [AlignedStep]
    let second: [AlignedStep]
    let firstIsPartial: Bool
    let secondIsPartial: Bool
    let identity: CompareIdentity

    func isPartial(_ side: Int) -> Bool { side == 1 ? firstIsPartial : secondIsPartial }
}

/// One row as four columns: what it establishes, each attempt's step, and the verdict.
struct CompareTableRow: View {
    let row: CompareRow
    let context: CompareRowContext
    let isCurrent: Bool
    let isActive: Bool
    var notice: CompareNotice?

    static let labelWidth: CGFloat = 140
    static let verdictWidth: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Text(context.identity.label(row))
                    .font(.callout.weight(.semibold))
                    .frame(width: Self.labelWidth, alignment: .leading)
                ForEach([1, 2], id: \.self) { side in
                    CompareCell(row: row, side: side, partial: context.isPartial(side))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                CompareVerdict(row: row, context: context)
                    .frame(width: Self.verdictWidth, alignment: .leading)
            }
            CompareRowNotice(notice: notice)
        }
        .compareRowFrame(row, context: context, isCurrent: isCurrent, isActive: isActive)
    }
}

/// One row as a card, where four columns do not fit.
struct CompareStackedRow: View {
    let row: CompareRow
    let context: CompareRowContext
    let isCurrent: Bool
    let isActive: Bool
    var notice: CompareNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(context.identity.label(row))
                .font(.callout.weight(.semibold))
            ForEach([1, 2], id: \.self) { side in
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.identity.title(side))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    CompareCell(row: row, side: side, partial: context.isPartial(side))
                }
            }
            CompareVerdict(row: row, context: context)
            CompareRowNotice(notice: notice)
        }
        .compareRowFrame(row, context: context, isCurrent: isCurrent, isActive: isActive)
    }
}

/// What came of an action on this row, under it.
private struct CompareRowNotice: View {
    let notice: CompareNotice?

    var body: some View {
        if let notice {
            Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.callout)
                .foregroundStyle(notice.isError ? ColorToken.refuted.color : .secondary)
        }
    }
}

/// The verdict chip, who decided the row, its note, and the row's actions.
private struct CompareVerdict: View {
    let row: CompareRow
    let context: CompareRowContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 6, lineSpacing: 4) {
                StatusBadge(style: CompareWording.verdict(row))
                CompareRowMenu(row: row, context: context)
            }
            Text(CompareWording.judged(row))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let note = context.identity.shielded(row.note) {
                MathText(note, showsProblems: false)
                    .captionMath()
            }
        }
    }
}

/// One step of one attempt in a row: its number and its text, provisional unless a person's ✓ counts on it
/// (invariant 3), with the key phrase marked and spelled out.
struct CompareCell: View {
    let step: AlignedStep?
    let side: Int
    let mark: Range<Int>?
    let phrase: String?
    /// The attempt stopped before it finished, so a missing step may be one it never reached.
    let partial: Bool

    init(row: CompareRow, side: Int, partial: Bool) {
        step = side == 1 ? row.a : row.b
        self.side = side
        mark = side == 1 ? row.markA : row.markB
        phrase = row.phrase(side)
        self.partial = partial
    }

    var body: some View {
        if let step {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(step.index)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Step \(step.index) of \(CompareWording.attempt(side))")
                    MathText(step.text, mark: mark)
                        .foregroundStyle((step.countsAsChecked ? ColorToken.ink : .secondaryInk).color)
                        .textSelection(.enabled)
                    Image(systemName: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .draggable(StepDrag(side: side, step: step.id))
                        .help("Drag onto a row of the other attempt to pair the steps")
                        .accessibilityHidden(true)
                }
                if let words = CompareWording.partsAt(phrase) {
                    MathText(words, showsProblems: false)
                        .captionMath()
                        .foregroundStyle(ColorToken.delicate.color)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(partial ? CompareWording.noMatchPartial : CompareWording.noMatch)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .padding(.horizontal, 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
        }
    }
}

/// The row's actions: re-pairing and a person's judgement. The same items are in the row's context menu; VoiceOver
/// has the judgements and Separate as actions, and pairing through this menu, so nothing needs a drag.
private struct CompareRowMenu: View {
    let row: CompareRow
    let context: CompareRowContext

    var body: some View {
        Menu {
            CompareRowActions(row: row, context: context)
        } label: {
            Label("Row Actions", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Pair, separate or judge these steps")
        .accessibilityLabel("Actions for \(context.identity.label(row))")
    }
}

/// The items of a row's menu.
struct CompareRowActions: View {
    let row: CompareRow
    let context: CompareRowContext

    @Environment(\.compareActions) private var actions

    var body: some View {
        let pair = context.pair
        if let a = row.a {
            Menu("Pair Step \(a.index) of \(CompareWording.attempt(1)) With") {
                ForEach(context.second) { b in
                    Button("Step \(b.index): \(b.establishes)") { actions?(.pair(RowKey(a: a.id, b: b.id), in: pair)) }
                        .disabled(row.b?.id == b.id)
                }
            }
        }
        if let b = row.b, row.a == nil {
            Menu("Pair Step \(b.index) of \(CompareWording.attempt(2)) With") {
                ForEach(context.first) { a in
                    Button("Step \(a.index): \(a.establishes)") { actions?(.pair(RowKey(a: a.id, b: b.id), in: pair)) }
                }
            }
        }
        if row.a != nil, row.b != nil {
            Button("Separate These Steps") { actions?(.unpair(row, in: pair)) }
            Divider()
            Button("Mark Equivalent") { actions?(.judge(row, .equivalent, in: pair)) }
            Button("Mark Diverging") { actions?(.judge(row, .diverge, in: pair)) }
            if row.judgedBy == .person {
                Button("Clear My Judgement") { actions?(.clear(row, in: pair)) }
            }
        }
    }
}

private extension View {
    /// The row's frame, its ring when current, its drop target and its actions for VoiceOver.
    func compareRowFrame(_ row: CompareRow, context: CompareRowContext, isCurrent: Bool, isActive: Bool) -> some View {
        modifier(CompareRowFrame(row: row, context: context, isCurrent: isCurrent, isActive: isActive))
    }
}

private struct CompareRowFrame: ViewModifier {
    let row: CompareRow
    let context: CompareRowContext
    let isCurrent: Bool
    let isActive: Bool

    @Environment(\.compareActions) private var actions
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        let pair = context.pair
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .statusFrame(CompareWording.verdict(row), cornerRadius: 8)
            .overlay {
                if isTargeted {
                    // A step dragged over a row it can pair with: dashed, so it reads without colour.
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                } else if isCurrent {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(isActive ? 1 : 0.35), lineWidth: 2)
                }
            }
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded { actions?(.focus(row.id)) })
            .dropDestination(for: StepDrag.self) { items, _ in
                guard let key = items.lazy.compactMap({ $0.pairing(onto: row) }).first else { return false }
                actions?(.pair(key, in: pair))
                return true
            } isTargeted: { isTargeted = $0 }
            .contextMenu { CompareRowActions(row: row, context: context) }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
            .accessibilityAction(named: "Make Current") { actions?(.focus(row.id)) }
            .accessibilityActions {
                if row.a != nil, row.b != nil {
                    Button("Mark Equivalent") { actions?(.judge(row, .equivalent, in: pair)) }
                    Button("Mark Diverging") { actions?(.judge(row, .diverge, in: pair)) }
                    Button("Separate These Steps") { actions?(.unpair(row, in: pair)) }
                    if row.judgedBy == .person {
                        Button("Clear My Judgement") { actions?(.clear(row, in: pair)) }
                    }
                }
            }
    }
}

#if DEBUG
#Preview("Compare rows, table and cards", traits: .fixture, .fixedLayout(width: 1000, height: 1300)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query var people: [Person]
    @Previewable @Query(filter: #Predicate<ProofAttempt> { $0.message != nil }) var attempts: [ProofAttempt]
    if let problem = problems.first, attempts.count >= 2 {
        let state = ComparisonState.read(attempts[0], attempts[1], in: problem, people: Set(people.map(\.stableID)))
        let identity = CompareIdentity.read(state, of: attempts[0], attempts[1], in: problem, windowBlind: false,
                                            choice: AlignerChoice.resolve(attempts[0], attempts[1], in: problem),
                                            people: people, catalog: .standard)
        let context = CompareRowContext(pair: state.pair, first: state.first.steps, second: state.second.steps,
                                        firstIsPartial: false, secondIsPartial: false, identity: identity)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.rows.suffix(2)) { row in
                    CompareTableRow(row: row, context: context, isCurrent: row.state == .diverge, isActive: true)
                }
                ForEach(state.rows.suffix(2)) { row in
                    CompareStackedRow(row: row, context: context, isCurrent: false, isActive: false)
                        .frame(width: 360)
                }
            }
            .padding()
        }
    }
}
#endif
