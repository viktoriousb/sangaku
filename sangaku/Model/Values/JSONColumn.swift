import Foundation

/// Structured payloads (alignment rows, Lean messages, request parameters) are stored as JSON `Data` behind
/// typed accessors, so the schema stays flat and CloudKit-compatible.
nonisolated enum JSONColumn {
    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// One Lean diagnostic, as parsed from `lake env lean --json`.
nonisolated struct LeanMessage: Codable, Hashable, Sendable {
    var severity: String
    var line: Int
    var column: Int
    var text: String
}

/// One row of a model's alignment of two attempts: the step of each attempt it pairs (side 1 is `stepAID`), what they
/// establish, and the model's verdict on the pair. The later fields are optional, so older rows still decode.
nonisolated struct AlignmentRow: Codable, Hashable, Sendable {
    var stepAID: UUID?
    var stepBID: UUID?
    var label: String
    var verdict: String
    /// The model's short reason, for a diverging row above all.
    var note: String?
    /// Where the two steps part ways, copied from each step's text.
    var keyPhraseA: String?
    var keyPhraseB: String?
    /// The revision of each step the model was shown: a later revision makes the row out of date.
    var revisionAID: UUID?
    var revisionBID: UUID?

    var alignmentVerdict: AlignmentVerdict { AlignmentVerdict(stored: verdict) }
}

/// Something `ContextBuilder` left out of a request because the model's window could not fit it.
nonisolated struct DroppedContextItem: Codable, Hashable, Sendable {
    var kind: String
    var title: String
    var tokens: Int
}
