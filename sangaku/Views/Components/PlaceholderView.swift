import SwiftUI

/// A workspace view that arrives in a later milestone.
struct PlaceholderView: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        }
    }
}
