import Foundation

/// Adopt in Compare. While blind mode hides the authors (invariant 9) it waits: adopting names the attempt, so the
/// verdict on which holds is recorded first, or blind mode turned off. Once shown, one choice per side, named only
/// through `CompareIdentity`, which holds no names while hidden. Adopting records no blind verdict.
enum CompareAdoption: Equatable {
    struct Choice: Equatable, Identifiable {
        var side: Int
        var attemptID: UUID
        var title: String
        var isAdopted: Bool

        var id: Int { side }
    }

    /// Not offered (a panel outside Compare).
    case none
    case waitingForVerdict
    case choices([Choice])

    static let blindCaption = "Adopting names the attempt: record which attempt holds first, or turn blind mode off."

    static func offer(identity: CompareIdentity, pair: ComparedPair, adopted: UUID?) -> CompareAdoption {
        guard !identity.hidden else { return .waitingForVerdict }
        return .choices([1, 2].map { side in
            let id = side == 1 ? pair.first : pair.second
            return Choice(side: side, attemptID: id, title: BranchWording.adoptTitle(identity.title(side)), isAdopted: id == adopted)
        })
    }
}
