import Foundation

/// A reply while it streams: the only thing that changes per token. Rows observe this object, not the thread,
/// and nothing here touches the store. Text is published at most every `interval`, with a trailing update, so
/// a fast stream does not re-typeset the reply on every delta.
@Observable
final class MessageStream {
    enum Phase: Equatable {
        /// A later prover of a shared fan-out, waiting for its turn.
        case queued
        case connecting, thinking, writing
    }

    private(set) var text = ""
    private(set) var phase: Phase
    /// The input side of the usage once the provider accepts the request.
    private(set) var usage: TokenUsage?
    private(set) var answeredModel: String?

    @ObservationIgnored private var pending = ""
    @ObservationIgnored private var lastPublished: ContinuousClock.Instant?
    @ObservationIgnored private var trailingFlush: Task<Void, Never>?
    @ObservationIgnored private let interval: Duration

    init(interval: Duration = .milliseconds(50), phase: Phase = .connecting) {
        self.interval = interval
        self.phase = phase
    }

    isolated deinit {
        trailingFlush?.cancel()
    }

    /// Everything received so far, published or not.
    var fullText: String { text + pending }

    func apply(_ event: ProviderEvent) {
        switch event {
        case .started(let model, let usage):
            answeredModel = model
            self.usage = usage
        case .thinking:
            if phase == .connecting { phase = .thinking }
        case .text(let delta):
            phase = .writing
            pending += delta
            publishIfDue()
        case .finished(_, let usage):
            self.usage = usage
            flush()
        }
    }

    /// Publishes everything received.
    func flush() {
        trailingFlush?.cancel()
        trailingFlush = nil
        guard !pending.isEmpty else { return }
        text += pending
        pending = ""
        lastPublished = .now
    }

    private func publishIfDue() {
        if let lastPublished, ContinuousClock.now - lastPublished < interval {
            guard trailingFlush == nil else { return }
            trailingFlush = Task { [weak self, interval] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        } else {
            flush()
        }
    }
}

extension MessageStream: Equatable {
    /// Identity: one object per live reply.
    static func == (lhs: MessageStream, rhs: MessageStream) -> Bool { lhs === rhs }
}
