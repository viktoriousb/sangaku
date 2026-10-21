import SwiftData
import SwiftUI

/// How long typing must pause before what a request would send, or a module that would run, is built again.
enum SheetTyping {
    static let pause = Duration.milliseconds(300)

    /// Waits for the pause; false if more typing came first.
    static func paused() async -> Bool {
        (try? await Task.sleep(for: pause)) != nil
    }
}

/// Asking a formalizer for a statement's Lean code: who drafts it, what it is told and what it costs. The draft arrives
/// in the thread and nothing is checked until a person clicks Check on it.
struct FormalizeSheet: View {
    let problem: Problem
    let statement: Statement
    let branch: Branch

    @Environment(\.threadManager) private var threads
    @Environment(\.dismiss) private var dismiss
    @State private var picked: UUID?
    @State private var request = ""
    /// What would be sent, built once typing pauses, and the request it was built for.
    @State private var basis: TaskBasis?
    @State private var builtFor: String?
    @State private var error: String?

    var body: some View {
        let formalizers = (problem.modelSlots ?? []).filter { $0.role == .formalizer }.sorted { $0.letter < $1.letter }
        let slot = picked ?? formalizers.first?.stableID
        VStack(alignment: .leading, spacing: 14) {
            Text("Formalize \(statement.label) in Lean").font(.headline)
            MathText(statement.statementLaTeX)
            Text(VerificationWording.formalizeExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if formalizers.isEmpty {
                Label(VerificationWording.noSlot(.formalizer), systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Formalizer", selection: Binding(get: { slot ?? formalizers[0].stableID }, set: { picked = $0 })) {
                    ForEach(formalizers, id: \.stableID) { Text("Model \($0.letter)").tag($0.stableID) }
                }
                .fixedSize()
            }
            TextField("Anything the formalizer should know (optional)", text: $request, axis: .vertical)
                .lineLimit(2...4)
            if let basis {
                DisclosureGroup("What is sent") { ToolTextBox(text: basis.text, label: "Text sent to the formalizer") }
                TaskEstimate(basis: basis, slot: slot, problem: problem, branch: branch)
            }
            SheetErrorLine(error: error)
            // Sent only once what is shown is what is sent.
            SheetButtons(confirm: "Ask Formalizer", disabled: slot == nil || builtFor != request) {
                guard let slot, let threads, let basis else { return }
                do throws(SendBlocker) {
                    try threads.requestTask(basis, slot: slot, problem: problem, branch: branch, effort: .standard)
                    VoiceOver.announce("The formalizer's draft will appear in the thread")
                    dismiss()
                } catch {
                    self.error = error.message
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .task(id: request) {
            if builtFor != nil { guard await SheetTyping.paused() else { return } }
            basis = .formalization(FormalizationBasis.make(statement, request: request))
            builtFor = request
        }
    }
}

/// What a task request would cost, or why it cannot be sent now.
struct TaskEstimate: View, Equatable {
    let basis: TaskBasis
    let slot: UUID?
    let problem: Problem
    let branch: Branch

    @Environment(\.threadManager) private var threads

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.basis == rhs.basis && lhs.slot == rhs.slot && lhs.problem === rhs.problem && lhs.branch === rhs.branch
    }

    var body: some View {
        if let slot, let threads {
            switch threads.taskPlan(basis, slot: slot, problem: problem, branch: branch, effort: .standard) {
            case .success(let recipient):
                Text("Estimate: " + UsageFormat.estimate(tokens: recipient.totalTokens, cost: recipient.cost,
                                                         outputCeiling: recipient.outputCeiling,
                                                         model: recipient.model.displayName).joined(separator: " · ") + ".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failure(let blocker):
                Label(blocker.message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(ColorToken.refuted.color)
            }
        }
    }
}

/// Checking a statement's Lean code: the code, editable on request, and the whole module that will run, since one
/// file per problem holds every checked statement. Check runs exactly the module shown (invariant 14); while the code
/// is being edited, the module is built again once typing pauses, and Check waits for it.
struct LeanCheckSheet: View {
    let problem: Problem
    let statement: Statement
    let candidate: LeanCandidate
    let startsEditing: Bool

    /// A module as built for one candidate.
    private struct Planned {
        var candidate: LeanCandidate
        var result: Result<LeanModulePlan, VerificationError>
    }

    @Environment(\.leanService) private var lean
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var statementPart = ""
    @State private var proofPart = ""
    @State private var planned: Planned?
    @State private var error: String?

    /// Edited code keeps its base: checked unchanged, it keeps the base's author (invariant 7).
    private var current: LeanCandidate {
        editing ? .typed(LeanSource(statementPart: statementPart, proofPart: proofPart), basedOn: candidate) : candidate
    }

    var body: some View {
        let shown = planned.flatMap { $0.candidate == current ? $0.result : nil }
        VStack(alignment: .leading, spacing: 12) {
            Text("Check \(statement.label) with Lean").font(.headline)
            MathText(statement.statementLaTeX)
            if editing {
                Text("Statement part: definitions, then `theorem main` and its type").font(.callout.weight(.medium))
                LeanEditor(text: $statementPart, label: "Statement part, Lean source", height: 110)
                Text("Proof, beginning with :=").font(.callout.weight(.medium))
                LeanEditor(text: $proofPart, label: "Proof, Lean source", height: 130)
            }
            switch shown ?? planned?.result {
            case .success(let module)?:
                let others = module.regions.filter { $0.statementID != statement.stableID }.compactMap { region in
                    (problem.statements ?? []).first { $0.stableID == region.statementID }?.label
                }
                Text(VerificationWording.moduleLine(others: others))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ToolTextBox(text: module.text, label: "The module that will run", copyTitle: "Copy Module")
                    .opacity(shown == nil ? 0.5 : 1)
            case .failure(let refusal)?:
                Label(refusal.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ColorToken.refuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                ProgressView().controlSize(.small)
            }
            if let refusal = lean?.workspace.refusal {
                HStack {
                    Label(refusal, systemImage: "gearshape").font(.callout)
                    SettingsLink { Text("Open Settings…") }
                }
            }
            Text(VerificationWording.checkExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SheetErrorLine(error: error)
            SheetButtons(confirm: "Check", disabled: (try? shown?.get()) == nil || lean?.workspace.record == nil) {
                if !editing { Button("Edit…") { startEditing() } }
            } middle: {
                EmptyView()
            } action: {
                guard case .success(let module)? = shown, let lean else { return }
                do throws(VerificationError) {
                    try lean.check(statement.stableID, candidate: current, shown: module.digest)
                    VoiceOver.announce("Checking with Lean")
                    dismiss()
                } catch {
                    self.error = error.message
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear { if startsEditing { startEditing() } }
        .task(id: current) {
            if editing, planned != nil { guard await SheetTyping.paused() else { return } }
            let candidate = current
            planned = Planned(candidate: candidate, result: plan(for: candidate))
        }
    }

    private func plan(for candidate: LeanCandidate) -> Result<LeanModulePlan, VerificationError> {
        guard let lean else { return .failure(.workspace("Lean is not available in this window.")) }
        return Result { () throws(VerificationError) in try lean.module(for: statement.stableID, candidate: candidate) }
    }

    /// Edits start from the candidate's code, even code the gate refuses (that is what editing is for); with none,
    /// from an empty target. What is checked then is the person's text.
    private func startEditing() {
        guard !editing else { return }
        let source = try? lean?.source(of: statement.stableID, candidate: candidate)
        statementPart = source?.statementPart ?? "theorem main : "
        proofPart = source?.proofPart ?? ":= by\n  sorry"
        editing = true
    }
}

/// A monospaced editor for Lean code.
struct LeanEditor: View {
    @Binding var text: String
    let label: String
    var height: CGFloat = 120

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .autocorrectionDisabled()
            .frame(height: height)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator) }
            .accessibilityLabel(label)
    }
}

/// A person's comparison of the checked Lean statement with the informal one (invariant 12). Recorded in their name,
/// on exactly the two texts shown.
struct FidelitySheet: View {
    let problem: Problem
    let statement: Statement

    @Environment(\.leanService) private var lean
    @Environment(\.dismiss) private var dismiss
    @State private var comment = ""
    @State private var error: String?

    /// Neither verdict is the default: Return records nothing here (invariant 12).
    static let confirmShortcut: KeyboardShortcut? = nil

    var body: some View {
        let leanStatement = statement.leanResult?.leanStatementSource ?? ""
        VStack(alignment: .leading, spacing: 14) {
            Text("Does the Lean statement say what \(statement.label) says?").font(.headline)
            if leanStatement.isEmpty {
                Text(VerificationError.noLeanResult.message).foregroundStyle(.secondary)
            } else {
                EqualColumnsLayout(minColumnWidth: 240) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Informal").font(.callout.weight(.semibold))
                        MathText(statement.statementLaTeX)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Lean").font(.callout.weight(.semibold))
                        ToolTextBox(text: leanStatement, label: "Lean statement")
                    }
                }
            }
            Text(VerificationWording.fidelityExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Comment (optional)", text: $comment, axis: .vertical)
                .lineLimit(1...3)
            SheetErrorLine(error: error)
            SheetButtons(confirm: "They Match", shortcut: Self.confirmShortcut, disabled: leanStatement.isEmpty) {
                EmptyView()
            } middle: {
                Button("They Differ") { record(.differs, leanStatement) }
                    .disabled(leanStatement.isEmpty)
            } action: {
                record(.matches, leanStatement)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func record(_ verdict: FidelityVerdict, _ leanStatement: String) {
        guard let lean else { return }
        do throws(VerificationError) {
            try lean.recordFidelity(verdict, statement: statement.stableID, seenLean: leanStatement,
                                    seenInformal: statement.statementLaTeX, comment: comment)
            VoiceOver.announce(verdict == .matches ? "Statement confirmed" : "Recorded that the statements differ")
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}
