import Foundation

/// The time a write is stamped with.
nonisolated enum Timestamps {
    /// Now, but always after `latest`: what is written next never seems older than what is already there, whatever the
    /// clock says.
    static func after(_ latest: Date?, now: Date) -> Date {
        max(now, (latest ?? .distantPast).addingTimeInterval(0.001))
    }
}
