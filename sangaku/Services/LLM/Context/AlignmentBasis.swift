import Foundation

/// The two attempts an alignment request shows the model, as plain values: each step's number, current text and
/// revision. Built once, on the main actor, when the request is prepared. The model's context is written from it and
/// its answer is mapped back through it, so what the model saw and how its step numbers are read cannot drift apart.
/// The attempts are "Attempt 1" and "Attempt 2" and nothing else: no author, no slot letter, no revision note.
nonisolated struct AlignmentBasis: Hashable, Sendable {
    nonisolated struct Step: Hashable, Sendable {
        var index: Int
        var stepID: UUID
        var revisionID: UUID?
        var establishes: String
        var text: String
    }

    nonisolated struct Side: Hashable, Sendable {
        var attemptID: UUID
        var messageID: UUID
        var steps: [Step]
        /// Stopped or cut off before it finished.
        var partial: Bool
    }

    var first: Side
    var second: Side

    var pair: ComparedPair { ComparedPair(first: first.attemptID, second: second.attemptID) }

    /// The user turn the aligner answers: both attempts, then what to return.
    var text: String {
        [Self.text(of: first, number: 1), Self.text(of: second, number: 2), Self.instruction].joined(separator: "\n\n")
    }

    static let instruction = "Align the steps of Attempt 1 and Attempt 2 above, as the output format requires."

    private static func text(of side: Side, number: Int) -> String {
        let header = side.partial
            ? "[Attempt \(number), to align: incomplete, it stopped before it finished]"
            : "[Attempt \(number), to align]"
        let steps = side.steps.map { "Step \($0.index) (establishes: \($0.establishes)): \($0.text)" }
        return ([header] + (steps.isEmpty ? ["(no steps)"] : steps)).joined(separator: "\n")
    }
}

extension AlignmentBasis {
    /// The two attempts as they stand now, in the comparison's order. Nil unless both have a message.
    static func make(_ pair: ComparedPair, first: ProofAttempt, second: ProofAttempt) -> AlignmentBasis? {
        guard let firstSide = side(first), let secondSide = side(second) else { return nil }
        return pair.first == first.stableID ? AlignmentBasis(first: firstSide, second: secondSide)
                                            : AlignmentBasis(first: secondSide, second: firstSide)
    }

    private static func side(_ attempt: ProofAttempt) -> Side? {
        guard let message = attempt.message else { return nil }
        return Side(attemptID: attempt.stableID, messageID: message.stableID, steps: attempt.sortedSteps.map { step in
            Step(index: step.index, stepID: step.stableID, revisionID: step.latestRevision?.stableID,
                 establishes: step.currentEstablishes, text: step.currentText)
        }, partial: message.outcome(isStreaming: false).isPartial)
    }
}
