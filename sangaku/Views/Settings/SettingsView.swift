import SwiftUI

/// The tabs of the Settings window, in order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case models, lean, computations, limits, export

    var id: Self { self }

    var title: String {
        switch self {
        case .models: "Models"
        case .lean: "Lean"
        case .computations: "Computations"
        case .limits: "Limits"
        case .export: "Export"
        }
    }

    var systemImage: String {
        switch self {
        case .models: "key"
        case .lean: "function"
        case .computations: "terminal"
        case .limits: "gauge.with.dots.needle.67percent"
        case .export: "square.and.arrow.up"
        }
    }
}

/// sangaku ▸ Settings… (⌘,), in five tabs, so each page fits on the screen. API keys go straight to the login
/// keychain; afterwards only their presence is shown. The window reopens on the tab last shown.
struct SettingsView: View {
    @Environment(\.credentialManager) private var credentials
    @Environment(\.toolSettings) private var toolSettings
    @Environment(\.leanService) private var lean
    @AppStorage("settings.tab") private var tab: SettingsTab = .models

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsPage { page(tab) }
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .task { await credentials?.refresh(ProviderID.anthropic) }
    }

    @ViewBuilder private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .models:
            Section {
                if let credentials {
                    APIKeyRow(providerID: ProviderID.anthropic, providerName: "Anthropic", credentials: credentials)
                }
            } header: {
                Text("Anthropic")
            } footer: {
                Text("The key is kept only in your login keychain. sangaku never shows it again and sends it only to Anthropic's API, with each request.")
                    .foregroundStyle(.secondary)
            }
        case .lean:
            if let lean, let toolSettings { LeanSettingsSection(lean: lean, settings: toolSettings) }
        case .computations:
            if let toolSettings { ToolSettingsSection(settings: toolSettings) }
        case .limits:
            if let toolSettings { LimitsSettingsSection(settings: toolSettings) }
        case .export:
            if let toolSettings { ExportSettingsSection(settings: toolSettings) }
        }
    }
}

/// One tab's page: a grouped form at the window's width, as tall as its content, so the window fits each tab.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct APIKeyRow: View {
    let providerID: String
    let providerName: String
    let credentials: CredentialManager

    @State private var entry = ""
    @State private var replacing = false
    @State private var working = false
    @State private var error: String?
    @State private var confirmingRemoval = false

    var body: some View {
        let state = credentials.state(for: providerID)
        VStack(alignment: .leading, spacing: 10) {
            if state == .stored && !replacing {
                HStack {
                    Label("A key is stored in your login keychain.", systemImage: "key.fill")
                    Spacer()
                    Button("Replace…") { replacing = true; error = nil }
                    Button("Remove…", role: .destructive) { confirmingRemoval = true }
                }
            } else {
                if case .unknown = state {
                    Label("Checking the keychain…", systemImage: "key")
                        .foregroundStyle(.secondary)
                } else if case .missing = state {
                    Label("No key is stored.", systemImage: "key")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    SecureField("\(providerName) API key", text: $entry, prompt: Text("Paste the key"))
                        .textContentType(.password)
                        .onSubmit(save)
                    if replacing {
                        Button("Cancel") { replacing = false; entry = ""; error = nil }
                    }
                    Button("Save", action: save)
                        .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                        .keyboardShortcut(.defaultAction)
                }
            }
            if case .unavailable(let message) = state {
                Label("The keychain could not be read: \(message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ColorToken.refuted.color)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ColorToken.refuted.color)
            }
        }
        .confirmationDialog("Remove the \(providerName) API key from the keychain?", isPresented: $confirmingRemoval) {
            Button("Remove Key", role: .destructive) {
                Task {
                    do throws(CredentialError) {
                        try await credentials.remove(for: providerID)
                        error = nil
                    } catch {
                        self.error = error.message
                    }
                }
            }
        } message: {
            Text("Problems that allow \(providerName) cannot be sent until you add a key again.")
        }
    }

    private func save() {
        let key = entry
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        working = true
        Task {
            defer { working = false }
            do throws(CredentialError) {
                try await credentials.save(key, for: providerID)
                entry = ""
                replacing = false
                error = nil
            } catch {
                self.error = error.message
            }
        }
    }
}

#if DEBUG
#Preview("Settings, no key") {
    SettingsView()
        .environment(\.credentialManager, CredentialManager(store: InMemorySecretStore()))
        .environment(\.toolSettings, ToolSettings(storage: .memory()))
}

#Preview("Settings, with Lean") {
    SettingsView().appEnvironment(PreviewFixtures.make().state)
}
#endif
