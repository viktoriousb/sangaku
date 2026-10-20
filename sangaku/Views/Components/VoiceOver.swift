import SwiftUI

/// Speech for changes VoiceOver would not otherwise notice: a confirmation or a refusal shown away from the focus.
enum VoiceOver {
    static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
