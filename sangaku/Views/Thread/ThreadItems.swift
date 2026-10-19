import SwiftData
import SwiftUI

/// The thread as rows: a fan-out's prompt and its attempts are one item; every other message, a referee's
/// included, is its own, in the order written.
enum ThreadItem: Identifiable {
    case message(Message)
    case fanOut(prompt: Message, fanOut: FanOut, attempts: [Message])

    var id: UUID {
        switch self {
        case .message(let message): message.stableID
        case .fanOut(let prompt, _, _): prompt.stableID
        }
    }

    /// `messages` oldest first, as a branch sorts them.
    static func make(_ messages: [Message]) -> [ThreadItem] {
        var grouped = Set<UUID>()
        var items: [ThreadItem] = []
        for message in messages {
            if let fanOut = message.fanOut {
                let attempts = (fanOut.attempts ?? []).compactMap(\.message).sorted { $0.createdAt < $1.createdAt }
                grouped.formUnion(attempts.map(\.stableID))
                items.append(.fanOut(prompt: message, fanOut: fanOut, attempts: attempts))
            } else if !grouped.contains(message.stableID) {
                items.append(.message(message))
            }
        }
        return items
    }
}

/// What the thread reads once per render and every item needs.
struct ThreadContext {
    let problem: Problem
    let branch: Branch
    let live: [UUID: MessageStream]
    let runs: [UUID: FanOutRun]
    let notices: [UUID: String]
    let authors: AuthorDirectory
    /// Something runs on the branch, so nothing new can start.
    let busy: Bool
    /// The fan-out each referee message judged.
    let refereeFanOuts: [UUID: FanOut]
    /// For each fan-out with a referee message: whether the latest one gave verdicts.
    let refereeGaveVerdicts: [UUID: Bool]

    init(problem: Problem, branch: Branch, items: [ThreadItem], messages: [Message], live: [UUID: MessageStream],
         runs: [UUID: FanOutRun], notices: [UUID: String], authors: AuthorDirectory, busy: Bool) {
        self.problem = problem
        self.branch = branch
        self.live = live
        self.runs = runs
        self.notices = notices
        self.authors = authors
        self.busy = busy
        var byMessage: [UUID: FanOut] = [:]
        for case .fanOut(let prompt, let fanOut, let attempts) in items {
            byMessage[prompt.stableID] = fanOut
            for attempt in attempts { byMessage[attempt.stableID] = fanOut }
        }
        var refereeFanOuts: [UUID: FanOut] = [:]
        var gaveVerdicts: [UUID: Bool] = [:]
        // Oldest first, so the latest referee message of each fan-out is the one that counts.
        for message in messages where message.kind == .referee {
            guard let fanOut = message.derivedFromIDs.lazy.compactMap({ byMessage[$0] }).first else { continue }
            refereeFanOuts[message.stableID] = fanOut
            gaveVerdicts[fanOut.stableID] = (fanOut.verdicts ?? []).contains { $0.messageID == message.stableID }
        }
        self.refereeFanOuts = refereeFanOuts
        refereeGaveVerdicts = gaveVerdicts
    }
}

/// One item of the thread.
struct ThreadItemView: View {
    let item: ThreadItem
    let context: ThreadContext
    let onViewContext: (RequestRecord) -> Void

    @Environment(\.threadManager) private var threads

    var body: some View {
        switch item {
        case .message(let message) where message.kind == .referee:
            RefereeMessageRow(message: message, stream: context.live[message.stableID],
                              fanOut: context.refereeFanOuts[message.stableID], authors: context.authors,
                              onViewContext: onViewContext,
                              onStop: { threads?.stop(messageID: message.stableID) })
        case .message(let message):
            MessageRow(message: message, stream: context.live[message.stableID], authors: context.authors,
                       onViewContext: onViewContext, onStop: { threads?.stop(messageID: message.stableID) })
        case .fanOut(let prompt, let fanOut, let attempts):
            VStack(alignment: .leading, spacing: 12) {
                MessageRow(message: prompt, stream: nil, authors: context.authors, onViewContext: onViewContext,
                           onStop: {})
                FanOutBlock(fanOut: fanOut, attempts: attempts, problem: context.problem, branch: context.branch,
                            live: context.live, run: context.runs[fanOut.stableID],
                            notice: context.notices[fanOut.stableID],
                            refereeGaveVerdicts: context.refereeGaveVerdicts[fanOut.stableID], busy: context.busy,
                            authors: context.authors, onViewContext: onViewContext)
            }
        }
    }
}
