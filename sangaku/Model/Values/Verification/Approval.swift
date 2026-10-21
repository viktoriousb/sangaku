import Foundation

/// A person's click on Run or Check, for exactly the text the button showed. Code written by a model or a person runs
/// only as a `SandboxJob`, and a job for such code can only be made from one of these (invariant 14). What runs is the
/// text inside the approval, never a view's copy; the only way to make one in the app is `given`, against what is
/// stored or planned at the click.
nonisolated struct Approval: Hashable, Sendable {
    nonisolated enum Refusal: Error, Hashable, Sendable {
        /// The code changed between showing it and the click.
        case changedSinceShown
    }

    let person: PersonID
    /// The text that will run.
    let text: String
    let digest: TextDigest
    let givenAt: Date

    private init(person: PersonID, text: String, at date: Date) {
        self.person = person
        self.text = text
        digest = TextDigest(of: text)
        givenAt = date
    }

    /// For stored code: `shown` is the digest the click carried; it must be the digest of what is stored now.
    static func given(by person: PersonID, shown: TextDigest, stored: String, at date: Date) throws(Refusal) -> Approval {
        guard TextDigest(of: stored) == shown else { throw .changedSinceShown }
        return Approval(person: person, text: stored, at: date)
    }

    #if DEBUG
    /// For tests that run code without a store.
    static func typed(by person: PersonID, text: String, at date: Date) -> Approval {
        Approval(person: person, text: text, at: date)
    }
    #endif
}
