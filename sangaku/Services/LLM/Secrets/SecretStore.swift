import Foundation
import Security
import Synchronization

/// Names of stored secrets.
nonisolated enum SecretAccount {
    static func apiKey(for providerID: String) -> String { "\(providerID)-api-key" }
}

nonisolated struct SecretStoreError: LocalizedError, Hashable, Sendable {
    var status: Int32
    var message: String

    var errorDescription: String? { message }
}

/// Where API keys live. Every call may block (the Keychain can show a system prompt), so none runs on the main
/// actor. Implementations never log a secret.
nonisolated protocol SecretStore: Sendable {
    @concurrent func read(_ account: String) async throws -> String?
    /// Whether a secret is stored, without reading it. For the Keychain this asks for attributes only, which
    /// never shows a prompt.
    @concurrent func exists(_ account: String) async throws -> Bool
    @concurrent func write(_ secret: String, account: String) async throws
    @concurrent func delete(_ account: String) async throws
}

/// Generic passwords in the login keychain. No data-protection keychain, so no entitlements are needed. With an
/// ad hoc signature macOS asks again after every rebuild, because the item trusts the exact build.
nonisolated struct KeychainSecretStore: SecretStore {
    var service = "local.sangaku"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @concurrent func read(_ account: String) async throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status) }
        guard let secret = String(data: data, encoding: .utf8) else {
            throw SecretStoreError(status: errSecDecode, message: "The stored key is not readable text.")
        }
        return secret
    }

    @concurrent func exists(_ account: String) async throws -> Bool {
        var request = query(account)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Self.error(status) }
        return true
    }

    @concurrent func write(_ secret: String, account: String) async throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Self.error(update) }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "sangaku: \(account)"
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    @concurrent func delete(_ account: String) async throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    private static func error(_ status: OSStatus) -> SecretStoreError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        return SecretStoreError(status: status, message: message)
    }
}

/// Secrets in memory only: tests, previews and the fixture, which must never touch the real Keychain.
nonisolated final class InMemorySecretStore: SecretStore {
    private let secrets: Mutex<[String: String]>

    init(_ secrets: [String: String] = [:]) {
        self.secrets = Mutex(secrets)
    }

    @concurrent func read(_ account: String) async throws -> String? {
        secrets.withLock { $0[account] }
    }

    @concurrent func exists(_ account: String) async throws -> Bool {
        secrets.withLock { $0[account] != nil }
    }

    @concurrent func write(_ secret: String, account: String) async throws {
        secrets.withLock { $0[account] = secret }
    }

    @concurrent func delete(_ account: String) async throws {
        _ = secrets.withLock { $0.removeValue(forKey: account) }
    }
}
