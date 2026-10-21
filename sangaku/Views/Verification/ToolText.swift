import SwiftUI

/// Code, Lean source or a tool's output exactly as written: monospaced, selectable, never typeset (invariant 16) and
/// never cut, so all of what a person approves is on screen (invariant 14). Up to a dozen lines it is shown whole;
/// longer text scrolls in a box of fixed height, one lazily built row per line. Copy copies all of it.
struct ToolTextBox: View {
    let text: String
    /// What VoiceOver calls it: "Code", "Output".
    var label: String
    var copyTitle = "Copy"

    static let shownLines = 12
    static let boxHeight: CGFloat = 200

    /// Every line of the text, none dropped: joined with line breaks they give the text back.
    static func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    var body: some View {
        let lines = Self.lines(of: text)
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if lines.count <= Self.shownLines {
                    Self.line(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    // Lines never wrap here: the box scrolls both ways, from its top-left corner.
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines.indices, id: \.self) {
                                Self.line(lines[$0]).fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .padding(8)
                    }
                    .defaultScrollAnchor(.topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.boxHeight)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(text)
            HStack(spacing: 8) {
                Button(copyTitle) { Pasteboard.copy(text) }
                    .buttonStyle(.link)
                    .font(.caption)
                if lines.count > Self.shownLines {
                    Text(VerificationWording.lineCount(lines.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func line(_ text: some StringProtocol) -> some View {
        Text(verbatim: text.isEmpty ? " " : String(text))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
    }
}
