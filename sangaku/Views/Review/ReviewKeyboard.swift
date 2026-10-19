import AppKit
import SwiftUI

/// Whether a text field or text view has the keyboard: then J, K, 1, 2, 3 and C are text, never commands. The
/// last of three checks, after the focus structure and Review's own focus state.
enum TextEditingProbe {
    static func isTyping(firstResponder: NSResponder?) -> Bool {
        firstResponder is NSText
    }
}

extension ReviewKeyInput {
    init(_ press: KeyPress) {
        self.init(characters: press.characters, command: press.modifiers.contains(.command),
                  option: press.modifiers.contains(.option), control: press.modifiers.contains(.control),
                  shift: press.modifiers.contains(.shift), isRepeat: press.phase == .repeat)
    }
}
