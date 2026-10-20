import SwiftUI

/// View switcher, model-slot chips and the inspector toggle.
struct WorkspaceToolbar: ToolbarContent {
    let window: WindowState

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ViewSwitcher(window: window)
        }
        ToolbarItem(placement: .primaryAction) {
            if window.hidesModelChrome {
                Label("Models hidden in blind mode", systemImage: "eye.slash")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .help("Blind mode hides which model wrote which attempt. Turn it off with ⌘⇧B.")
            } else {
                ModelSlotChips(window: window)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(window.inspectorPresented ? "Hide Proof Structure" : "Show Proof Structure",
                   systemImage: "sidebar.trailing") {
                window.inspectorPresented.toggle()
            }
            .help("Proof structure (⌥⌘I)")
        }
    }
}

private struct ViewSwitcher: View {
    let window: WindowState

    var body: some View {
        @Bindable var window = window
        Picker("View", selection: $window.activeView) {
            ForEach(WorkspaceView.allCases) { view in
                Text(view.title).tag(view)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(window.selectedProblemID == nil)
        .help("Thread ⌘1 · Compare ⌘2 · Review ⌘3 · Branches ⌘4")
    }
}

/// One chip per model slot: letter and role, with the model in the tooltip. Clicking a chip changes its role or
/// model; the add button adds a slot with the next free letter.
private struct ModelSlotChips: View {
    let window: WindowState
    @Environment(\.problemManager) private var problems
    @Environment(\.threadManager) private var threads

    var body: some View {
        let problem = problems?.problem(id: window.selectedProblemID)
        let catalog = threads?.catalog ?? .standard
        HStack(spacing: 6) {
            ForEach(problem?.sortedModelSlots ?? []) { slot in
                SlotMenu(slot: slot, catalog: catalog)
            }
            Button("Add Model", systemImage: "plus.circle") {
                guard let problem, let problems, let threads else { return }
                let providerID = threads.defaultProviderID
                problems.addSlot(to: problem, providerID: providerID,
                                 modelID: catalog.defaultModel(for: providerID)?.id ?? "")
            }
            .labelStyle(.iconOnly)
            .disabled(problem == nil)
            .help("Add a model to this problem, as a prover")
        }
    }
}

/// A slot's chip as a menu: its role and its model. Messages it already wrote keep the role and model they were
/// written with.
private struct SlotMenu: View {
    let slot: ModelSlot
    let catalog: ModelCatalog
    @Environment(\.problemManager) private var problems

    var body: some View {
        let models = catalog.models(for: slot.providerID)
        Menu {
            Section("Role") {
                Picker("Role", selection: Binding(get: { slot.role }, set: { problems?.setRole($0, for: slot) })) {
                    ForEach(SlotRole.allCases, id: \.self) { role in
                        Text(Self.title(role)).tag(role)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Model") {
                Picker("Model", selection: Binding(get: { slot.modelID }, set: { problems?.setModel($0, for: slot) })) {
                    ForEach(models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                    if !models.contains(where: { $0.id == slot.modelID }) {
                        Text("\(slot.modelID) (not offered)").tag(slot.modelID)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            ModelSlotChip(slot: slot, modelName: catalog.resolve(slot.modelID).displayName)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Model \(slot.letter), \(slot.role.rawValue), \(catalog.resolve(slot.modelID).displayName)")
        .accessibilityHint("Change the role or the model")
    }

    static func title(_ role: SlotRole) -> String {
        switch role {
        case .prover: "Prover"
        case .referee: "Referee"
        case .formalizer: "Formalizer (no prompt yet)"
        case .scout: "Scout (no prompt yet)"
        }
    }
}
