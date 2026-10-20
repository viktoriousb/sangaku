import Foundation
import SwiftData

extension SangakuSchemaV1 {
    /// A research problem: the pinned statement every model sees, plus everything worked out about it.
    @Model final class Problem {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var title: String = ""
        var statementLaTeX: String = ""
        /// Providers this problem may be sent to (invariant 15). Empty means none yet.
        var allowedProviderIDs: [String] = []
        /// The branch that holds the main line: a pointer, never a branch state. Moved only by adopting an attempt.
        var mainBranchID: UUID?
        /// The adopted attempt, whose steps are the pinned theorem's proof, and who adopted it when. A record of a
        /// person's choice; the theorem's status still derives from those steps (invariants 1 and 13).
        var adoptedAttemptID: UUID?
        var adoptedByID: UUID?
        var adoptedAt: Date?
        /// The statement the pinned card shows a status for, usually the main theorem.
        var pinnedStatementID: UUID?
        var createdByID: UUID?

        @Relationship(deleteRule: .cascade, inverse: \NotationEntry.problem)
        var notation: [NotationEntry]? = []
        @Relationship(deleteRule: .cascade, inverse: \Branch.problem)
        var branches: [Branch]? = []
        @Relationship(deleteRule: .cascade, inverse: \Statement.problem)
        var statements: [Statement]? = []
        @Relationship(deleteRule: .cascade, inverse: \ModelSlot.problem)
        var modelSlots: [ModelSlot]? = []
        @Relationship(deleteRule: .cascade, inverse: \Alignment.problem)
        var alignments: [Alignment]? = []

        init(title: String = "", statementLaTeX: String = "") {
            self.title = title
            self.statementLaTeX = statementLaTeX
        }

        var sortedNotation: [NotationEntry] {
            (notation ?? []).sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
        }

        var sortedBranches: [Branch] {
            (branches ?? []).sorted { ($0.createdAt, $0.stableID.uuidString) < ($1.createdAt, $1.stableID.uuidString) }
        }

        /// The main line, or the first branch if the pointer is missing.
        var mainBranch: Branch? {
            sortedBranches.first { $0.stableID == mainBranchID } ?? sortedBranches.first
        }

        var sortedModelSlots: [ModelSlot] {
            (modelSlots ?? []).sorted { $0.letter < $1.letter }
        }
    }

    /// A person who works on problems. Referenced by `PersonID` from reviews and authorship, never by
    /// relationship, so provenance survives edits to people.
    @Model final class Person {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var name: String = ""
        var initials: String = ""
        /// The person using this copy of the app.
        var isMe: Bool = false

        init(name: String = "", initials: String = "", isMe: Bool = false) {
            self.name = name
            self.initials = initials
            self.isMe = isMe
        }

        var personID: PersonID { PersonID(stableID) }
    }

    /// A model taking part in a problem under a letter (A, B, C…) and a role.
    @Model final class ModelSlot {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var letter: String = ""
        var providerID: String = ""
        var modelID: String = ""
        var roleRaw: String = SlotRole.fallback.rawValue
        var colorTokenRaw: String = ""
        var problem: Problem?

        init(letter: String = "", providerID: String = "", modelID: String = "", role: SlotRole = .prover) {
            self.letter = letter
            self.providerID = providerID
            self.modelID = modelID
            self.roleRaw = role.rawValue
        }

        var role: SlotRole {
            get { SlotRole(stored: roleRaw) }
            set { roleRaw = newValue.rawValue }
        }

        var slotID: ModelSlotID { ModelSlotID(stableID) }
    }

    /// One convention in a problem's notation registry. `macroDefinition` holds a canonical preamble line
    /// (`\newcommand{\Z}{\mathbb{Z}}`), which round-trips and feeds every render and every prompt.
    @Model final class NotationEntry {
        var stableID: UUID = UUID()
        var createdAt: Date = Date.now
        var sortIndex: Int = 0
        var symbolLaTeX: String = ""
        var meaning: String = ""
        var macroDefinition: String?
        var includeInContext: Bool = true
        var problem: Problem?

        init(symbolLaTeX: String = "", meaning: String = "", macroDefinition: String? = nil, includeInContext: Bool = true) {
            self.symbolLaTeX = symbolLaTeX
            self.meaning = meaning
            self.macroDefinition = macroDefinition
            self.includeInContext = includeInContext
        }
    }
}
