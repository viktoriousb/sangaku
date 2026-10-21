import CryptoKit
import Foundation

/// The SHA-256 of a text, in lower-case hex. Binds a decision to the exact text it was made on: a Run or Check click
/// carries the digest of the code it showed, and a stored result the digest of the source it checked.
nonisolated struct TextDigest: Hashable, Codable, Sendable {
    let hex: String

    init(of text: String) {
        hex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
