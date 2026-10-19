import SwiftUI

/// sangaku ▸ Settings… (⌘,). API keys go straight to the login keychain; afterwards only their presence is
/// shown.
struct SettingsView: View {
    @Environment(\.credentialManager) private var credentials

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await credentials?.refresh(ProviderID.anthropic) }
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
}
#endif
