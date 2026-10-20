import CoreTransferable
import UniformTypeIdentifiers

/// A dragged step: which attempt and which step. It travels as its own content type, so only Compare's rows take it;
/// a text field, the composer included, never does.
nonisolated struct StepDrag: Codable, Hashable, Sendable, Transferable {
    var side: Int
    var step: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sangakuStep)
    }

    /// The pair a drop makes: the dropped step with the row's step of the other attempt. Nil when the row has no
    /// step on the other side, or the step dropped is the row's own.
    func pairing(onto row: CompareRow) -> RowKey? {
        if side == 2, let a = row.a, row.b?.id != step { return RowKey(a: a.id, b: step) }
        if side == 1, let b = row.b, row.a?.id != step { return RowKey(a: step, b: b.id) }
        return nil
    }
}

extension UTType {
    /// A step dragged in Compare. Declared in the app's Info.plist (`UTExportedTypeDeclarations`).
    nonisolated static let sangakuStep = UTType(exportedAs: "local.sangaku.step")
}
