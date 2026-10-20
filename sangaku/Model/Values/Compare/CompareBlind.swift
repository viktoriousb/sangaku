import Foundation

/// Which attempt is "Attempt 1": fixed per pair from the two attempts' IDs alone, never from slot letters, times or
/// the order the person picked them in. Blind or not, the columns never swap.
nonisolated enum SideOrder {
    static func orient(_ x: UUID, _ y: UUID) -> (first: UUID, second: UUID) {
        let (low, high) = x.uuidString < y.uuidString ? (x, y) : (y, x)
        // FNV-1a over both IDs' bytes, in a fixed order, so the result is the same whichever is passed first.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for id in [low, high] {
            withUnsafeBytes(of: id.uuid) { bytes in
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 0x0000_0100_0000_01B3
                }
            }
        }
        return hash & 1 == 0 ? (low, high) : (high, low)
    }
}

/// Blind mode (invariant 9): the authors of a comparison stay hidden while the window is blind and the person has
/// not recorded which attempt holds.
nonisolated enum CompareBlind {
    static func hides(windowBlind: Bool, verdictRecorded: Bool) -> Bool {
        windowBlind && !verdictRecorded
    }
}

/// The person's blind verdict: which attempt holds up. A record only; it changes no review, check or status.
nonisolated enum HoldsVerdict: String, CaseIterable, Hashable, Sendable {
    case first, second, both, neither
}

/// A guard on text a model wrote (a row's note or label) shown while blind: text that names a model, a slot letter
/// in an identifying form, or a provider is withheld. The aligner is told to write "Attempt 1/2"; this makes sure.
nonisolated enum BlindShield {
    /// The identifying forms of each slot letter, matched as written, and each name, matched in any case.
    nonisolated struct Vocabulary: Hashable, Sendable {
        var exact: [String]
        var anyCase: [String]

        init(letters: [String], names: [String]) {
            exact = letters.flatMap { letter in
                ["Model \(letter)", "model \(letter)", "\(letter)'s", "\(letter)’s", "slot \(letter)", "Slot \(letter)",
                 "Prover \(letter)", "prover \(letter)", "Referee \(letter)", "referee \(letter)"]
            }
            anyCase = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
        }
    }

    static func isSafe(_ text: String, _ vocabulary: Vocabulary) -> Bool {
        !vocabulary.exact.contains { text.contains($0) }
            && !vocabulary.anyCase.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }
}
