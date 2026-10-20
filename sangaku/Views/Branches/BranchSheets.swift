import SwiftData
import SwiftUI

/// Names a new branch forked from a message. Nothing is copied: the branch reads the history up to that message.
struct NewBranchSheet: View {
    let problem: Problem
    let messageID: UUID
    let onCreated: (Branch) -> Void

    @Environment(\.branchManager) private var branches
    @Environment(\.dismiss) private var dismiss
    @Query private var messages: [Message]
    @Query private var people: [Person]
    @State private var name = ""
    @State private var error: String?

    init(problem: Problem, messageID: UUID, onCreated: @escaping (Branch) -> Void) {
        self.problem = problem
        self.messageID = messageID
        self.onCreated = onCreated
        _messages = Query(filter: #Predicate<Message> { $0.stableID == messageID })
    }

    var body: some View {
        let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
        VStack(alignment: .leading, spacing: 14) {
            Text("New Branch").font(.headline)
            if let message = messages.first, let owner = message.branch {
                // The fork starts with every message its parent shows up to this one.
                let count = (owner.visibleHistory.position(of: message.stableID) ?? -1) + 1
                VStack(alignment: .leading, spacing: 4) {
                    Text("Forks from").font(.caption).foregroundStyle(.secondary)
                    MathText(BranchWording.messageLabel(author: authors.name(of: message.author),
                                                        text: Self.text(of: message)), showsProblems: false)
                    MathText("on \(owner.name)", showsProblems: false).font(.caption).foregroundStyle(.secondary)
                }
                Text(BranchWording.inherited(count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(BranchError.noSuchMessage.message).foregroundStyle(.secondary)
            }
            TextField("Name", text: $name, prompt: Text("What this branch tries"))
            SheetErrorLine(error: error)
            SheetButtons(confirm: "Create Branch", disabled: messages.isEmpty) { create() }
        }
        .padding(20)
        .frame(width: 480)
    }

    static func text(of message: Message) -> String {
        message.proofAttempt.map { _ in AttemptCard.source(of: message, stream: nil) } ?? message.bodyLaTeX
    }

    private func create() {
        guard let branches else { return }
        do {
            let branch = try branches.fork(from: messageID, named: name)
            VoiceOver.announce("Branch \(branch.name) created")
            dismiss()
            onCreated(branch)
        } catch {
            self.error = error.message
        }
    }
}

/// Why a branch died (or was parked), and the exact text sent to models, written by a person. Each text can start from
/// a message the branch shows, which is recorded; no model writes or drafts a reason.
struct ReasonSheet: View {
    let problem: Problem
    let branchID: UUID
    let mode: ReasonMode

    @Environment(\.branchManager) private var branches
    @Environment(\.dismiss) private var dismiss
    /// The branch, as a query so the sheet follows the store.
    @Query private var found: [Branch]
    @Query private var people: [Person]
    @State private var draft = ReasonDraft()
    @State private var loaded = false
    @State private var error: String?

    init(problem: Problem, branchID: UUID, mode: ReasonMode) {
        self.problem = problem
        self.branchID = branchID
        self.mode = mode
        _found = Query(filter: #Predicate<Branch> { $0.stableID == branchID })
    }

    var body: some View {
        let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
        let wording = BranchWording.reasonTitle(mode)
        VStack(alignment: .leading, spacing: 14) {
            if let branch = found.first {
                let forModels = mode == .deadEnd || (mode == .edit && branch.state == .deadEnd)
                let heading = mode == .park || branch.state == .parked && mode == .edit ? "Note for people" : "Why it died"
                MathText("\(wording.title): \(branch.name)", showsProblems: false).font(.headline)
                startMenu(branch: branch, authors: authors, forModels: forModels)
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading)
                        .font(.callout.weight(.medium))
                    TextEditor(text: $draft.reason)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator) }
                        .accessibilityLabel("\(heading), LaTeX source")
                    if BranchReasons.trimmed(draft.reason) != nil {
                        MathText(draft.reason).font(.callout)
                    }
                }
                if forModels {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sent to models as").font(.callout.weight(.medium))
                        TextEditor(text: $draft.reasonForModels)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 60)
                            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator) }
                            .accessibilityLabel("Text sent to models")
                        Text("Left empty, the reason above is sent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("In Context: send it with every new prompt", isOn: $draft.includeInContext)
                        Text(draft.includeInContext
                             ? ContextBuilder.deadEndLine(.init(id: branch.stableID, createdAt: branch.createdAt,
                                                                name: branch.name, text: draft.textForModels))
                             : BranchWording.sent(state: .deadEnd, inContext: false))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if mode == .park {
                    Text(BranchWording.sent(state: .parked, inContext: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(BranchError.noSuchBranch.message).foregroundStyle(.secondary)
            }
            SheetErrorLine(error: error)
            SheetButtons(confirm: wording.action, disabled: found.isEmpty) { save() }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: load)
        .onChange(of: found.count) { load() }
    }

    /// Copies a message the branch shows into either text.
    private func startMenu(branch: Branch, authors: AuthorDirectory, forModels: Bool) -> some View {
        let messages = branch.visibleHistory.all.reversed()
        return Menu("Start from a Message") {
            ForEach(Array(messages), id: \.stableID) { message in
                let text = NewBranchSheet.text(of: message)
                let label = BranchWording.messageLabel(author: authors.name(of: message.author), text: text)
                if forModels {
                    Menu(label) {
                        Button("Copy into Why It Died") { draft.start(.people, from: text, messageID: message.stableID) }
                        Button("Copy into Sent to Models") { draft.start(.models, from: text, messageID: message.stableID) }
                    }
                } else {
                    Button(label) { draft.start(.people, from: text, messageID: message.stableID) }
                }
            }
        }
        .fixedSize()
        .disabled(messages.isEmpty)
        .help("Copy a message into a text and edit it; the message it came from is recorded")
    }

    private func load() {
        guard !loaded, let branch = found.first else { return }
        loaded = true
        draft = ReasonDraft(reason: branch.reason ?? "", reasonForModels: branch.reasonForModels ?? "",
                            includeInContext: branch.state == .deadEnd ? branch.includeReasonInContext : true,
                            reasonFromMessageID: branch.reasonFromMessageID,
                            modelTextFromMessageID: branch.modelTextFromMessageID)
    }

    private func save() {
        guard let branches, let branch = found.first else { return }
        do {
            switch mode {
            case .deadEnd: try branches.markDeadEnd(branch, draft)
            case .park: try branches.park(branch, draft)
            case .edit: try branches.editReasons(of: branch, draft)
            }
            VoiceOver.announce(mode == .edit ? "Reasons saved" : "\(branch.name) is \(mode == .park ? "parked" : "a dead end")")
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}

/// Adopting an attempt as the main line: what it does, what to know first, and nothing more. Every warning shown is
/// acknowledged by confirming; if what is known changes before then, the manager refuses and the sheet shows the new
/// warnings.
struct AdoptSheet: View {
    let problem: Problem
    let attemptID: UUID

    @Environment(\.branchManager) private var branches
    @Environment(\.problemManager) private var problems
    @Environment(\.dismiss) private var dismiss
    @Query private var attempts: [ProofAttempt]
    @Query private var people: [Person]
    @State private var error: String?

    init(problem: Problem, attemptID: UUID) {
        self.problem = problem
        self.attemptID = attemptID
        _attempts = Query(filter: #Predicate<ProofAttempt> { $0.stableID == attemptID })
    }

    var body: some View {
        let authors = AuthorDirectory(problem: problem, people: people, catalog: .standard)
        let assessment = branches?.assessment(ofAttempt: attemptID)
        let author = attempts.first?.message.map { authors.name(of: $0.author) } ?? "this"
        let theorem = problems?.pinnedStatement(of: problem)?.label ?? "The theorem"
        VStack(alignment: .leading, spacing: 14) {
            Text("Adopt \(author)'s Attempt as the Main Line").font(.headline)
            if let assessment {
                MathText(BranchWording.adoptEffect(steps: assessment.stepCount, theorem: theorem,
                                                   branch: assessment.branchName, alreadyMain: assessment.branchIsMain),
                         showsProblems: false)
                    .fixedSize(horizontal: false, vertical: true)
                Text(BranchWording.adoptChecksNothing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(([assessment.progress.headline] + assessment.progress.notes).joined(separator: " · "))
                    .font(.callout)
                if !assessment.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(assessment.warnings, id: \.self) { warning in
                            Label(warning.message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(ColorToken.delicate.color)
                        }
                    }
                    .font(.callout)
                }
                if let refusal = assessment.refusal {
                    Label(refusal.message, systemImage: "xmark.octagon")
                        .foregroundStyle(ColorToken.refuted.color)
                        .font(.callout)
                }
            } else {
                Text(BranchError.noSuchAttempt.message).foregroundStyle(.secondary)
            }
            SheetErrorLine(error: error)
            SheetButtons(confirm: assessment?.warnings.isEmpty == false ? "Adopt Anyway" : "Adopt",
                         disabled: assessment == nil || assessment?.refusal != nil) {
                adopt(acknowledging: Set(assessment?.warnings ?? []))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func adopt(acknowledging warnings: Set<AdoptionWarning>) {
        guard let branches else { return }
        do {
            try branches.adopt(attempt: attemptID, acknowledging: warnings)
            VoiceOver.announce("Adopted as the main line")
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}

#if DEBUG
#Preview("New branch", traits: .fixture, .sizeThatFitsLayout) {
    @Previewable @Query var problems: [Problem]
    @Previewable @Query(filter: #Predicate<Message> { $0.kindRaw == "attempt" }) var attempts: [Message]
    if let problem = problems.first, let message = attempts.first {
        NewBranchSheet(problem: problem, messageID: message.stableID) { _ in }
    }
}

#Preview("Mark as dead end", traits: .fixture, .sizeThatFitsLayout) {
    @Previewable @Query var problems: [Problem]
    // The fork: live, and its reasons can start from its parent's messages.
    if let problem = problems.first,
       let branch = problem.sortedBranches.first(where: { $0.state == .live && $0.forkedFrom != nil }) {
        ReasonSheet(problem: problem, branchID: branch.stableID, mode: .deadEnd)
    }
}

#Preview("Edit reasons of a parked branch, dark", traits: .fixture, .sizeThatFitsLayout) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first, let branch = problem.sortedBranches.first(where: { $0.state == .parked }) {
        ReasonSheet(problem: problem, branchID: branch.stableID, mode: .edit)
            .preferredColorScheme(.dark)
    }
}

#Preview("Adopt, with warnings", traits: .fixture, .sizeThatFitsLayout) {
    @Previewable @Query var problems: [Problem]
    if let problem = problems.first, let attempt = problem.sortedBranches.flatMap({ $0.sortedMessages })
        .compactMap(\.proofAttempt).first(where: { $0.stableID != problem.adoptedAttemptID }) {
        AdoptSheet(problem: problem, attemptID: attempt.stableID)
    }
}
#endif
