import Foundation

/// The life of one fan-out while it runs: which attempts are waiting, running or ended, and whether the referee
/// waits, runs or was cancelled. Pure: `ThreadManager` feeds it events and carries out the commands it returns,
/// so the order of things (invariant 4: the referee only after every attempt has ended) is decided here alone.
nonisolated struct FanOutRun: Hashable, Sendable {
    nonisolated enum MemberState: Hashable, Sendable {
        /// A later prover of a shared fan-out, waiting for the ones before it.
        case queued
        case running
        /// Finished, stopped or failed, and its output read.
        case ended
    }

    nonisolated enum RefereeState: Hashable, Sendable {
        case none
        /// Starts when every attempt has ended.
        case pending(slotID: UUID)
        case running
        case done
        /// Stop all was used before it could start.
        case cancelled
    }

    nonisolated struct Member: Hashable, Sendable {
        var messageID: UUID
        var state: MemberState
    }

    nonisolated enum Event: Hashable, Sendable {
        case memberEnded(UUID)
        /// Stop all: nothing more starts, and a pending referee is cancelled.
        case stopAll
        /// A person asks for the referee (the "Referee with" button).
        case refereeRequested(slotID: UUID)
        case refereeEnded
        /// The app is quitting: nothing more starts.
        case shutdown
    }

    nonisolated enum Command: Hashable, Sendable {
        case startMember(UUID)
        case startReferee(slotID: UUID)
    }

    let fanOutID: UUID
    let problemID: UUID
    let branchID: UUID
    /// Shared visibility: one prover at a time, in order, each seeing the attempts before it.
    let sequential: Bool
    let effort: ThinkingEffort
    private(set) var members: [Member]
    private(set) var referee: RefereeState
    private(set) var halted = false

    /// A fan-out just sent: every prover starts at once, or only the first when they take turns.
    static func begin(fanOutID: UUID, problemID: UUID, branchID: UUID, members: [UUID], sequential: Bool,
                      refereeSlotID: UUID?, effort: ThinkingEffort) -> (FanOutRun, [Command]) {
        let starting = sequential ? Array(members.prefix(1)) : members
        let run = FanOutRun(
            fanOutID: fanOutID, problemID: problemID, branchID: branchID, sequential: sequential, effort: effort,
            members: members.map { Member(messageID: $0, state: starting.contains($0) ? .running : .queued) },
            referee: refereeSlotID.map { .pending(slotID: $0) } ?? .none)
        return (run, starting.map(Command.startMember))
    }

    /// A fan-out whose attempts all ended before this session (or whose run was already settled), for a referee
    /// started by hand.
    static func settled(fanOutID: UUID, problemID: UUID, branchID: UUID, members: [UUID],
                        effort: ThinkingEffort) -> FanOutRun {
        FanOutRun(fanOutID: fanOutID, problemID: problemID, branchID: branchID, sequential: false, effort: effort,
                  members: members.map { Member(messageID: $0, state: .ended) }, referee: .none)
    }

    var allMembersEnded: Bool { members.allSatisfy { $0.state == .ended } }

    /// Nothing is running or waiting: the run can be forgotten.
    var isSettled: Bool {
        guard allMembersEnded else { return false }
        return switch referee {
        case .pending, .running: false
        case .none, .done, .cancelled: true
        }
    }

    var refereePending: Bool {
        if case .pending = referee { true } else { false }
    }

    mutating func handle(_ event: Event) -> [Command] {
        switch event {
        case .memberEnded(let id):
            guard let index = members.firstIndex(where: { $0.messageID == id }) else { return [] }
            members[index].state = .ended
            return next()
        case .stopAll, .shutdown:
            halted = true
            if refereePending { referee = .cancelled }
            return []
        case .refereeRequested(let slotID):
            guard allMembersEnded, referee != .running else { return [] }
            referee = .running
            return [.startReferee(slotID: slotID)]
        case .refereeEnded:
            if referee == .running { referee = .done }
            return []
        }
    }

    /// What starts once something has ended: the next prover in turn, else the referee once every attempt ended.
    private mutating func next() -> [Command] {
        guard !halted else { return [] }
        if sequential, !members.contains(where: { $0.state == .running }),
           let index = members.firstIndex(where: { $0.state == .queued }) {
            members[index].state = .running
            return [.startMember(members[index].messageID)]
        }
        if allMembersEnded, case .pending(let slotID) = referee {
            referee = .running
            return [.startReferee(slotID: slotID)]
        }
        return []
    }
}
