import SwiftData
import SwiftUI

/// Who wrote what, read once per thread render rather than in every row.
struct AuthorDirectory: Equatable {
    struct SlotInfo: Equatable {
        var letter: String
        var colorToken: ColorToken?
        var role: SlotRole
        var modelName: String
    }

    /// How a model's message is credited: the slot's letter and colour, the role the message was written in and the
    /// model that wrote it. Editing a slot later never relabels what it wrote.
    struct Attribution {
        var letter: String
        var colorToken: ColorToken?
        var role: SlotRole?
        var modelName: String
    }

    /// A person as the margin and the review chips show them.
    struct PersonProfile: Equatable {
        var name: String
        var initials: String
    }

    /// Who wrote or reviewed something, in the margin: a letter or initials (the cue that never rests on colour), a
    /// colour and a name.
    struct AuthorMark: Hashable {
        var text: String
        var colorToken: ColorToken
        var name: String
    }

    /// What a person whose record is gone is called, everywhere.
    static let missingPerson = "Someone no longer listed"

    /// The stable IDs of the problem's people: who can check, confirm and accept (invariant 1).
    var personIDs: Set<UUID> { Set(profiles.keys) }

    var profiles: [UUID: PersonProfile] = [:]
    var slots: [UUID: SlotInfo] = [:]
    /// The person using the app.
    let meID: UUID?
    let catalog: ModelCatalog

    /// The catalog is fixed data, so two directories are equal when their people and slots are.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profiles == rhs.profiles && lhs.slots == rhs.slots && lhs.meID == rhs.meID
    }

    init(problem: Problem, people: [Person], catalog: ModelCatalog) {
        self.catalog = catalog
        meID = Person.me(among: people)?.stableID
        profiles = Dictionary(people.map { person in
            let initials = person.initials.trimmingCharacters(in: .whitespaces)
            return (person.stableID, PersonProfile(name: person.name, initials: initials.isEmpty ? person.name : initials))
        }, uniquingKeysWith: { first, _ in first })
        slots = Dictionary(problem.sortedModelSlots.map { slot in
            (slot.stableID, SlotInfo(letter: slot.letter, colorToken: ColorToken(rawValue: slot.colorTokenRaw),
                                     role: slot.role, modelName: catalog.resolve(slot.modelID).displayName))
        }, uniquingKeysWith: { first, _ in first })
    }

    func name(of author: Author?) -> String {
        switch author {
        case .model(let slotID): "Model \(letter(of: slotID))"
        case .human(let person): name(ofPerson: person.rawValue)
        case nil: "Unknown author"
        }
    }

    func letter(of slotID: ModelSlotID) -> String {
        slots[slotID.rawValue]?.letter ?? "?"
    }

    /// A model by its letter, a person by name: "A", "MK".
    func shortName(of author: Author?) -> String {
        if case .model(let slotID) = author { return letter(of: slotID) }
        return name(of: author)
    }

    /// A model by its slot's letter and colour; me in ink; other people in the co-author grey. Slots without a colour
    /// of their own share the grey: their letter tells them apart.
    func mark(of author: Author?) -> AuthorMark {
        switch author {
        case .model(let slotID):
            let slot = slots[slotID.rawValue]
            return AuthorMark(text: slot?.letter ?? "?", colorToken: slot?.colorToken ?? .coauthor, name: name(of: author))
        case .human(let person):
            let profile = profiles[person.rawValue]
            return AuthorMark(text: profile?.initials ?? "?", colorToken: person.rawValue == meID ? .ink : .coauthor,
                              name: name(ofPerson: person.rawValue))
        case nil:
            return AuthorMark(text: "?", colorToken: .secondaryInk, name: "Unknown author")
        }
    }

    /// A person's name, from their stable ID.
    func name(ofPerson id: UUID?) -> String {
        id.flatMap { profiles[$0]?.name } ?? Self.missingPerson
    }

    /// A person's initials, as the review chips show them.
    func initials(ofPerson id: UUID?) -> String {
        id.flatMap { profiles[$0]?.initials } ?? Self.missingPerson
    }

    /// The referee slot's letter, for "Checked by C only".
    func refereeLetter(_ slotID: UUID?) -> String {
        slotID.flatMap { slots[$0]?.letter } ?? "the referee"
    }

    /// For a message written by a model: the role from the message's kind and the model from its request record,
    /// falling back to the slot only when there is no record.
    func attribution(of message: Message) -> Attribution? {
        guard case .model(let slotID) = message.author else { return nil }
        let slot = slots[slotID.rawValue]
        let model = message.request.map { catalog.resolve($0.answeredModelID ?? $0.modelID).displayName }
        return Attribution(letter: slot?.letter ?? "?", colorToken: slot?.colorToken,
                           role: message.kind.authoringRole ?? slot?.role, modelName: model ?? slot?.modelName ?? "unknown model")
    }
}

/// One message. A model's reply is unchecked math, so it is drawn provisional (invariant 3): the "Proposed"
/// glyph and label, secondary ink and a dotted frame. Its state (stopped, declined, failed) always shows as a
/// glyph and words.
struct MessageRow: View {
    let message: Message
    let stream: MessageStream?
    let authors: AuthorDirectory
    let onViewContext: (RequestRecord) -> Void
    let onStop: () -> Void

    @Environment(\.branchActions) private var branchActions

    var body: some View {
        let outcome = message.outcome(isStreaming: stream != nil)
        let isModel = if case .model = message.author { true } else { false }
        VStack(alignment: .leading, spacing: 10) {
            header(isModel: isModel)
            if let stream {
                if message.kind == .leanDraft || message.kind == .compute {
                    TaskStreamingBody(kind: message.kind, stream: stream)
                } else {
                    LiveReplyBody(stream: stream)
                }
            } else if message.kind == .compute, let cell = message.computeCell {
                ComputeCellBody(message: message, cell: cell, authors: authors)
            } else if message.kind == .leanDraft, let draft = message.leanDraft {
                LeanDraftBody(message: message, draft: draft, authors: authors)
            } else {
                MessageBody(message: message, isModel: isModel)
            }
            if outcome != .complete && outcome != .streaming {
                OutcomeLine(outcome: outcome, stopReason: message.request?.stopReason)
            }
            if let record = message.request, stream == nil {
                RequestFooter(record: record) { onViewContext(record) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MessageFrame(isModel: isModel))
        .contextMenu {
            if stream == nil, message.computeCell != nil || message.leanDraft != nil {
                VerificationMessageMenu(message: message)
            } else {
                Button("Copy LaTeX Source") {
                    Pasteboard.copy(stream?.fullText ?? message.bodyLaTeX)
                }
            }
            if let record = message.request {
                Button("View Context…") { onViewContext(record) }
            }
            ForkMenuItem(message: message, running: stream != nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message from \(authors.name(of: message.author))")
        .forkAction(message: message, running: stream != nil, actions: branchActions)
    }

    private func header(isModel: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let attribution = authors.attribution(of: message) {
                ModelByline(attribution: attribution)
            } else if case .human(let person) = message.author {
                Text(authors.name(ofPerson: person.rawValue))
                    .font(.callout.weight(.semibold))
            } else {
                Text(message.kind == .system ? "Note" : "Unknown author")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            if stream != nil {
                Button("Stop", systemImage: "stop.circle", action: onStop)
                    .buttonStyle(.borderless)
                    .help("Stop this reply; what has arrived is kept")
            }
            if isModel {
                // No person has checked a model's reply.
                StatusBadge(style: StatusStyle.style(for: .proposed), compact: true)
            }
        }
    }
}

/// A finished message. Compute cells show their code. Attempts and referee messages have their own rows.
private struct MessageBody: View {
    let message: Message
    let isModel: Bool

    var body: some View {
        let ink = isModel ? StatusStyle.style(for: .proposed).ink.color : ColorToken.ink.color
        VStack(alignment: .leading, spacing: 8) {
            if message.kind == .compute || message.kind == .leanDraft {
                // Output that could not be read as a cell or a draft, kept as it arrived; nothing here can run.
                Text(message.bodyLaTeX)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            } else if !message.bodyLaTeX.isEmpty {
                MathText(message.bodyLaTeX)
                    .foregroundStyle(ink)
                    .textSelection(.enabled)
            } else {
                Text("No reply text was saved.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A reply while it streams. Only this view observes the stream, so tokens re-render nothing else.
struct LiveReplyBody: View {
    let stream: MessageStream

    var body: some View {
        let (closed, pending) = StreamingTail.split(stream.text)
        VStack(alignment: .leading, spacing: 6) {
            if !closed.isEmpty {
                MathText(closed)
                    .foregroundStyle(StatusStyle.style(for: .proposed).ink.color)
            }
            if !pending.isEmpty {
                Text(pending)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Formula still arriving: \(pending)")
            }
            StreamPhaseLabel(phase: stream.phase)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

#if DEBUG
#Preview("Messages", traits: .fixture, .fixedLayout(width: 760, height: 900)) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query var people: [Person]
    @Previewable @Query(sort: \Message.createdAt) var messages: [Message]
    if let problem = problems.first {
        let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
        ScrollView {
            VStack(spacing: 12) {
                ForEach(messages.suffix(6), id: \.stableID) { message in
                    MessageRow(message: message, stream: nil, authors: authors, onViewContext: { _ in }, onStop: {})
                }
            }
            .padding()
        }
    }
}
#endif
