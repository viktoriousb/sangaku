import Foundation

/// Who the composer sends to, held per branch for the session. It names slots by stable ID and is read against the
/// problem's slots as they are at send time, so a slot whose role changed simply drops out.
nonisolated struct SendSelection: Hashable, Sendable {
    /// Prover slots chosen as recipients. Empty means the first prover.
    var recipients: Set<UUID> = []
    /// For two or more provers: whether they see each other's attempts.
    var visibility = FanOutVisibility.independent
    /// A referee slot that judges the attempts once they have all ended.
    var refereeSlotID: UUID?

    /// The selection with one prover added or taken away. `chosen` is who receives it now; at least one prover
    /// always stays.
    func toggling(_ slotID: UUID, on: Bool, chosen: Set<UUID>) -> SendSelection {
        var selection = self
        var recipients = chosen
        if on {
            recipients.insert(slotID)
        } else if recipients.count > 1 {
            recipients.remove(slotID)
        }
        selection.recipients = recipients
        return selection
    }

    func resolved(_ slots: [ProblemSnapshot.SlotDigest]) -> ResolvedSelection {
        let provers = slots.filter { $0.role == .prover }.sorted { $0.letter < $1.letter }
        let chosen = provers.filter { recipients.contains($0.id.rawValue) }
        let referee = slots.first { $0.id.rawValue == refereeSlotID && $0.role == .referee }
        return ResolvedSelection(provers: chosen.isEmpty ? Array(provers.prefix(1)) : chosen, referee: referee,
                                 visibility: visibility)
    }
}

/// A selection read against the problem's slots.
nonisolated struct ResolvedSelection: Hashable, Sendable {
    /// In letter order, which is the order a shared fan-out runs in.
    var provers: [ProblemSnapshot.SlotDigest]
    var referee: ProblemSnapshot.SlotDigest?
    var visibility: FanOutVisibility

    /// Two or more provers, or a referee: each prover writes a structured attempt. One prover alone writes a prose
    /// reply.
    var isFanOut: Bool { provers.count >= 2 || referee != nil }
}
