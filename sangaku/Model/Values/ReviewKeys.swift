import Foundation

/// What a key in the Review step list does.
nonisolated enum ReviewCommand: Hashable, Sendable {
    case next, previous
    case mark(ReviewVerdict)
    case comment
}

/// A key press as a keyboard-driven list (Review's steps, Compare's rows) sees it. Caps lock and the numeric keypad
/// are deliberately not modifiers here.
nonisolated struct ListKeyInput: Hashable, Sendable {
    var characters: String
    var command = false
    var option = false
    var control = false
    var shift = false
    /// The key is held down and repeating.
    var isRepeat = false
}

nonisolated enum ReviewKeys {
    static let legend = "J / K between steps · 1 2 3 to mark · C to comment"

    private static let table: [String: ReviewCommand] = [
        "j": .next, "k": .previous, "1": .mark(.correct), "2": .mark(.wrong), "3": .mark(.unclear), "c": .comment,
    ]

    /// The characters the step list listens for, either case.
    static let characters = CharacterSet(charactersIn: table.keys.joined() + table.keys.joined().uppercased())

    /// J, K, 1, 2, 3 and C, unmodified. Nil for any modifier, any other key, and whenever the person is typing:
    /// a plain letter is then text, never a command. A held key repeats only J and K.
    static func command(for input: ListKeyInput, isTyping: Bool) -> ReviewCommand? {
        guard !isTyping, !input.command, !input.option, !input.control, !input.shift,
              let command = table[input.characters.lowercased()] else { return nil }
        guard !input.isRepeat || command == .next || command == .previous else { return nil }
        return command
    }
}

nonisolated enum ReviewNavigation {
    /// The step after or before `current` in `order` (`ListNavigation`). Other commands do not move.
    static func move<ID: Equatable>(_ command: ReviewCommand, from current: ID?, in order: [ID]) -> ID? {
        switch command {
        case .next: ListNavigation.move(forward: true, from: current, in: order)
        case .previous: ListNavigation.move(forward: false, from: current, in: order)
        case .mark, .comment: order.isEmpty ? nil : current
        }
    }
}

/// Moving through a list with J and K.
nonisolated enum ListNavigation {
    /// The item after or before `current` in `order`, stopping at the ends. With no current item (or one no longer
    /// listed), forward goes to the first item and back to the last.
    static func move<ID: Equatable>(forward: Bool, from current: ID?, in order: [ID]) -> ID? {
        guard !order.isEmpty else { return nil }
        guard let position = current.flatMap(order.firstIndex(of:)) else { return forward ? order.first : order.last }
        return order[forward ? min(position + 1, order.count - 1) : max(position - 1, 0)]
    }
}
