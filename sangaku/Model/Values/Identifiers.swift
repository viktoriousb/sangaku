import Foundation

/// A person, referenced by the `stableID` of their `Person` record. Provenance stores IDs rather than
/// relationships so it survives deleting or merging records.
nonisolated struct PersonID: Hashable, Codable, Sendable {
    let rawValue: UUID
    init(_ rawValue: UUID) { self.rawValue = rawValue }
}

/// A model slot, referenced by the `stableID` of its `ModelSlot` record.
nonisolated struct ModelSlotID: Hashable, Codable, Sendable {
    let rawValue: UUID
    init(_ rawValue: UUID) { self.rawValue = rawValue }
}

/// Who wrote something: a person or a model slot.
nonisolated enum Author: Hashable, Codable, Sendable {
    case human(PersonID)
    case model(ModelSlotID)

    var isHuman: Bool {
        if case .human = self { true } else { false }
    }

    /// The two columns a model stores: a kind and an ID.
    var stored: (kind: String, id: UUID) {
        switch self {
        case .human(let id): ("human", id.rawValue)
        case .model(let id): ("model", id.rawValue)
        }
    }

    /// Rebuilds an author from stored columns. Unknown or missing values give nil, never a guess.
    init?(kind: String?, id: UUID?) {
        guard let id else { return nil }
        switch kind {
        case "human": self = .human(PersonID(id))
        case "model": self = .model(ModelSlotID(id))
        default: return nil
        }
    }
}
