import SwiftData
import SwiftUI

/// Asking a scout for a computation that tests a claim: which statement a run's evidence is attached to, which tools
/// can run, who writes it and what it costs. The cell arrives in the thread and waits for a person's Run.
struct ScoutSheet: View {
    let problem: Problem
    let seed: ScoutSeed
    let branch: Branch

    /// What the request is built from: the statement chosen and the person's words.
    private struct Inputs: Hashable {
        var target: UUID?
        var request: String
    }

    @Environment(\.threadManager) private var threads
    @Environment(\.toolSettings) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var picked: UUID?
    @State private var target: UUID?
    @State private var request = ""
    /// What would be sent, built once typing pauses, and the inputs it was built for.
    @State private var basis: TaskBasis?
    @State private var builtFor: Inputs?
    @State private var error: String?

    var body: some View {
        let scouts = (problem.modelSlots ?? []).filter { $0.role == .scout }.sorted { $0.letter < $1.letter }
        let slot = picked ?? scouts.first?.stableID
        let statements = seed.statements.compactMap { id in (problem.statements ?? []).first { $0.stableID == id } }
        let statement = statements.first { $0.stableID == target } ?? statements.first
        let tools = runnableTools
        VStack(alignment: .leading, spacing: 14) {
            Text(seed.fromCompare ? "Search for a Counterexample" : "Ask for a Check").font(.headline)
            MathText(seed.claim)
            if statements.count > 1 {
                Picker("Evidence is attached to", selection: Binding(get: { statement?.stableID ?? statements[0].stableID },
                                                                    set: { target = $0 })) {
                    ForEach(statements, id: \.stableID) { Text($0.label).tag($0.stableID) }
                }
                .fixedSize()
            } else if let statement {
                Text("Evidence is attached to \(statement.label).").font(.callout)
            }
            Text(VerificationWording.scoutExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if tools.isEmpty {
                HStack {
                    Label("No computation tool is set up.", systemImage: "wrench.and.screwdriver")
                    SettingsLink { Text("Open Settings…") }
                }
            } else {
                Text("Can run: " + tools.map { ToolID($0).displayName }.joined(separator: ", ") + ".").font(.callout)
            }
            if scouts.isEmpty {
                Label(VerificationWording.noSlot(.scout), systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Scout", selection: Binding(get: { slot ?? scouts[0].stableID }, set: { picked = $0 })) {
                    ForEach(scouts, id: \.stableID) { Text("Model \($0.letter)").tag($0.stableID) }
                }
                .fixedSize()
            }
            TextField("What to look for (optional)", text: $request, axis: .vertical)
                .lineLimit(2...4)
            if let basis {
                DisclosureGroup("What is sent") { ToolTextBox(text: basis.text, label: "Text sent to the scout") }
                TaskEstimate(basis: basis, slot: slot, problem: problem, branch: branch)
            }
            SheetErrorLine(error: error)
            // Sent only once what is shown is what is sent.
            SheetButtons(confirm: "Ask Scout",
                         disabled: slot == nil || basis == nil || builtFor != Inputs(target: target, request: request)) {
                send(slot: slot)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task(id: Inputs(target: target, request: request)) {
            if builtFor != nil { guard await SheetTyping.paused() else { return } }
            let inputs = Inputs(target: target, request: request)
            let statement = statements.first { $0.stableID == inputs.target } ?? statements.first
            basis = statement.flatMap { statement in
                guard let settings, !runnableTools.isEmpty else { return nil }
                return .scout(ScoutBasis.make(statement, claim: seed.claim, request: inputs.request, tools: runnableTools,
                                              seconds: Int(settings.values.computeSeconds),
                                              memoryGiB: settings.values.computeMemoryGiB))
            }
            builtFor = inputs
        }
    }

    /// The tools that are set up and can run.
    private var runnableTools: [EvidenceTool] {
        EvidenceTool.allCases.filter { settings?.resolution(ToolID($0)).path != nil }
    }

    private func send(slot: UUID?) {
        guard let slot, let threads, let basis else { return }
        do throws(SendBlocker) {
            try threads.requestTask(basis, slot: slot, problem: problem, branch: branch, effort: .standard)
            VoiceOver.announce("The scout's computation will appear in the thread")
            dismiss()
        } catch {
            self.error = error.message
        }
    }
}

/// A computation a person writes, or edits from another cell. It goes into the thread as theirs and runs only when they
/// click Run on it.
struct CellEditorSheet: View {
    let problem: Problem
    let statement: Statement
    let basedOn: ComputeCell?
    let branch: Branch

    @Environment(\.computeService) private var compute
    @Environment(\.dismiss) private var dismiss
    @State private var tool = EvidenceTool.python
    @State private var code = ""
    @State private var scope = ""
    @State private var claim = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(basedOn == nil ? "New Computation for \(statement.label)" : "Edit as My Computation").font(.headline)
            Picker("Tool", selection: $tool) {
                ForEach(EvidenceTool.allCases, id: \.self) { Text(ToolID($0).displayName).tag($0) }
            }
            .fixedSize()
            Text("Code, self-contained; end with a line `sangaku-result: holds`, `counterexample …` or `inconclusive …`")
                .font(.callout.weight(.medium))
            LeanEditor(text: $code, label: "Code", height: 200)
            TextField("Scope: exactly what it covers", text: $scope)
            TextField("Claim it tests (optional)", text: $claim)
            SheetErrorLine(error: error)
            SheetButtons(confirm: "Add to Thread") {
                guard let compute else { return }
                do throws(VerificationError) {
                    try compute.writeCell(on: branch, statement: statement.stableID, tool: tool, code: code, scope: scope,
                                          claim: claim, basedOn: basedOn?.stableID)
                    VoiceOver.announce("Your computation is in the thread; run it there")
                    dismiss()
                } catch {
                    self.error = error.message
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            guard let basedOn, code.isEmpty else { return }
            tool = basedOn.tool
            code = basedOn.code
            scope = basedOn.scope
            claim = basedOn.claim
        }
    }
}

/// A person accepting a computation's counterexample as refuting a statement (rule 1). Shows the run and says what
/// accepting does; the note is the person's own words, and it is what every model is told.
struct RefutationSheet: View {
    let problem: Problem
    let statement: Statement
    let evidence: Evidence

    @Environment(\.statementGraph) private var graph
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        let reading = CellOutputReader.read(evidence.output)
        VStack(alignment: .leading, spacing: 12) {
            Text("Accept the Refutation of \(statement.label)?").font(.headline)
            MathText(statement.statementLaTeX)
            MathText(VerificationWording.refutationRun(tool: evidence.tool, scope: evidence.scope)).font(.callout)
            // What the program printed, as printed: never typeset.
            Text(verbatim: reading.detail.isEmpty ? "It named no counterexample." : "Reported: " + reading.detail)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Code") { ToolTextBox(text: evidence.code, label: "Code that ran") }
            DisclosureGroup("Output") { ToolTextBox(text: evidence.output, label: "Output") }
            Text(VerificationWording.refutationConsequence(statement.label))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Why it is refuted, in your words (sent to every model)", text: $note, axis: .vertical)
                .lineLimit(2...4)
            SheetErrorLine(error: error)
            SheetButtons(confirm: "Accept Refutation", disabled: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                guard let graph else { return }
                do throws(VerificationError) {
                    try graph.acceptRefutation(statement.stableID, evidence: evidence.stableID, note: note, in: problem)
                    VoiceOver.announce("\(statement.label) is refuted")
                    dismiss()
                } catch {
                    self.error = error.message
                }
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

/// Looking an attempt's citations up: exactly what is sent, and where, before anything leaves the Mac (invariant 6).
struct CitationCheckSheet: View {
    let attempt: ProofAttempt

    @Environment(\.citationService) private var citations
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        let facts = CitationFact.read(attempt)
        VStack(alignment: .leading, spacing: 12) {
            Text("Check Citations").font(.headline)
            Text(VerificationWording.citationExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if facts.isEmpty {
                Text("This attempt cites nothing.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Step \(fact.stepIndex): \(fact.text)")
                            Text(VerificationWording.sends(fact.text))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            SheetErrorLine(error: error)
            SheetButtons(confirm: facts.count == 1 ? "Check 1 Citation" : "Check \(facts.count) Citations",
                         disabled: facts.isEmpty) {
                guard let citations else { return }
                do throws(VerificationError) {
                    try citations.check(facts.map { ShownCitation(id: $0.id, text: $0.text) })
                    VoiceOver.announce("Checking citations")
                    dismiss()
                } catch {
                    self.error = error.message
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// A person adding a citation to a step.
struct CitationAddSheet: View {
    let step: Step

    @Environment(\.citationService) private var citations
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Citation to Step \(step.index)").font(.headline)
            TextField("Authors, title or book, year, and the theorem or section", text: $text)
            Text("It starts unchecked; Check Citations looks it up.").font(.caption).foregroundStyle(.secondary)
            SheetErrorLine(error: error)
            SheetButtons(confirm: "Add", disabled: text.trimmingCharacters(in: .whitespaces).isEmpty) {
                guard let citations else { return }
                do throws(VerificationError) {
                    try citations.add(text, to: step.stableID)
                    VoiceOver.announce("Citation added")
                    dismiss()
                } catch {
                    self.error = error.message
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
