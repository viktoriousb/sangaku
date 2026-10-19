import Foundation

/// Whether each provider's API key is stored. It never holds or shows a key: Settings writes one straight to
/// the store, and only the provider reads it, inside a request. Nothing is read at launch; the state is checked
/// when Settings opens or the composer first needs it.
@Observable
final class CredentialManager {
    nonisolated enum KeyState: Hashable, Sendable {
        case unknown, stored, missing
        case unavailable(String)
    }

    private(set) var states: [String: KeyState] = [:]

    @ObservationIgnored private let store: any SecretStore

    init(store: any SecretStore) {
        self.store = store
    }

    func state(for providerID: String) -> KeyState {
        states[providerID] ?? .unknown
    }

    /// Checks whether a key is stored, without reading it (no Keychain prompt).
    func refresh(_ providerID: String) async {
        do {
            let exists = try await store.exists(SecretAccount.apiKey(for: providerID))
            states[providerID] = exists ? .stored : .missing
        } catch {
            states[providerID] = .unavailable(Self.describe(error))
        }
    }

    /// Stores a key. Surrounding whitespace is removed; an empty key is refused.
    func save(_ key: String, for providerID: String) async throws(CredentialError) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CredentialError(message: "Paste a key first.") }
        do {
            try await store.write(trimmed, account: SecretAccount.apiKey(for: providerID))
            states[providerID] = .stored
        } catch {
            throw CredentialError(message: Self.describe(error))
        }
    }

    func remove(for providerID: String) async throws(CredentialError) {
        do {
            try await store.delete(SecretAccount.apiKey(for: providerID))
            states[providerID] = .missing
        } catch {
            throw CredentialError(message: Self.describe(error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? SecretStoreError)?.message ?? error.localizedDescription
    }
}

nonisolated struct CredentialError: Error, Hashable, Sendable {
    var message: String
}
