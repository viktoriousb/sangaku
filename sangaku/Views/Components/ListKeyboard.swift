import AppKit
import SwiftUI

/// Whether a text field or text view has the keyboard: then a list's letter keys (Review's J, K, 1, 2, 3 and C, J and K
/// in Compare and Branches) are text, never commands. The last of three checks, after the focus structure and the
/// list's own focus state.
enum TextEditingProbe {
    static func isTyping(firstResponder: NSResponder?) -> Bool {
        firstResponder is NSText
    }

    /// Whether a key is text rather than a command: the list does not have the keyboard, or a text view does.
    static func typing(listHasFocus: Bool) -> Bool {
        !listHasFocus || isTyping(firstResponder: NSApp.keyWindow?.firstResponder)
    }
}

extension ListKeyInput {
    init(_ press: KeyPress) {
        self.init(characters: press.characters, command: press.modifiers.contains(.command),
                  option: press.modifiers.contains(.option), control: press.modifiers.contains(.control),
                  shift: press.modifiers.contains(.shift), isRepeat: press.phase == .repeat)
    }
}
