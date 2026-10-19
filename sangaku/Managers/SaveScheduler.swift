import Foundation
import SwiftData

/// The one save path. Mutations mark the store dirty; a save follows after a quiet period, on deactivation and
/// before quitting. Streaming tokens never call `markDirty`. A failed save is kept in `lastError` (shown in
/// every window) and retried until it succeeds.
@Observable
final class SaveScheduler {
    private(set) var lastError: String?
    private(set) var saveCount = 0

    @ObservationIgnored private let hasChanges: () -> Bool
    @ObservationIgnored private let save: () throws -> Void
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var pending: Task<Void, Never>?

    convenience init(context: ModelContext, delay: Duration = .seconds(1.5), retryDelay: Duration = .seconds(10),
                     sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.init(hasChanges: { context.hasChanges }, save: { try context.save() },
                  delay: delay, retryDelay: retryDelay, sleep: sleep)
    }

    init(hasChanges: @escaping () -> Bool, save: @escaping () throws -> Void, delay: Duration = .seconds(1.5),
         retryDelay: Duration = .seconds(10), sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.hasChanges = hasChanges
        self.save = save
        self.delay = delay
        self.retryDelay = retryDelay
        self.sleep = sleep
    }

    /// Restarts the quiet period.
    func markDirty() {
        schedule(after: delay)
    }

    /// Saves now if anything changed. On failure the error is kept and a retry is scheduled.
    func flush() {
        pending?.cancel()
        pending = nil
        guard hasChanges() else { return }
        do {
            try save()
            saveCount += 1
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            schedule(after: retryDelay)
        }
    }

    private func schedule(after interval: Duration) {
        pending?.cancel()
        pending = Task { [weak self, sleep] in
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
