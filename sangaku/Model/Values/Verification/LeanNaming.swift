import Foundation

/// The names the app gives Lean code. A statement's Lean code sits in its own namespace in the problem's module, and
/// its target is always `main`, so the app, never the code, decides which declaration is checked (invariant 12).
nonisolated enum LeanNaming {
    /// The first 12 hex digits of a stable ID, lower case.
    static func short(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// `Sangaku.S1a2b3c4d5e6f`: the namespace of a statement's code.
    static func namespace(for statement: UUID) -> String { "Sangaku.S" + short(statement) }

    /// The target's full name, as `#print axioms` reports it: `Sangaku.S1a2b3c4d5e6f.main`.
    static func declaration(for statement: UUID) -> String { namespace(for: statement) + ".main" }
}

/// What the app's kernel check reported for a statement's declaration. Only `LeanOutputReader` makes `.ran` from a
/// check; a stored result gives it back only when the kernel check reported (`LeanResult.axiomCheck`).
nonisolated enum AxiomCheck: Hashable, Sendable {
    /// The kernel check did not run or did not report this declaration as a theorem: the axioms are unknown.
    case notRun
    /// `axioms` may be empty: "does not depend on any axioms".
    case ran(declaration: String, axioms: [String])
}
