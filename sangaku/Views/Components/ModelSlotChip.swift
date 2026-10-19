import SwiftData
import SwiftUI

/// A model slot's letter or a person's initials on their colour, as in the toolbar, message headers, the composer
/// and comments. The text takes the background's colour, so it reads in light and dark mode alike: the colour
/// tokens are dark in light mode and light in dark mode.
struct AuthorBadge: View {
    let text: String
    let colorToken: ColorToken?

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(Color(nsColor: .textBackgroundColor))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, text.count > 1 ? 3 : 0)
            .background((colorToken ?? .coauthor).color, in: .rect(cornerRadius: 4))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// One slot: letter, role and, in its tooltip, the model.
struct ModelSlotChip: View {
    let slot: ModelSlot
    var modelName: String

    var body: some View {
        HStack(spacing: 5) {
            AuthorBadge(text: slot.letter, colorToken: ColorToken(rawValue: slot.colorTokenRaw))
            Text(slot.role.rawValue.capitalized)
                .font(.caption)
        }
        .help("Model \(slot.letter), \(slot.role.rawValue): \(modelName)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Model \(slot.letter), role \(slot.role.rawValue), \(modelName)")
    }
}

#if DEBUG
#Preview("Slot chips", traits: .fixture) {
    @Previewable @Query(sort: \ModelSlot.letter) var slots: [ModelSlot]
    HStack {
        ForEach(slots) { slot in
            ModelSlotChip(slot: slot, modelName: ModelCatalog.standard.resolve(slot.modelID).displayName)
        }
    }
    .padding()
}
#endif
