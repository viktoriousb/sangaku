import SwiftData
import SwiftUI

/// Prose with inline (`$…$`, `\(…\)`) and display (`$$…$$`, `\[…\]`) math. Every formula is set exactly by
/// tier 1 or tier 2, or shown as its source with a warning and the reason underneath (invariant 16).
///
/// Ink comes from the caller's `.foregroundStyle`, so unchecked math can be drawn in `secondaryInk`.
struct MathText: View {
    private let source: String
    private let showsProblems: Bool
    private let mark: Range<Int>?

    @Environment(\.mathRenderer) private var renderer
    @Environment(\.mathContext) private var context

    /// - Parameter showsProblems: whether to list unrenderable formulas under the text. Compact places
    ///   (sidebar rows) turn it off; the source chip itself still shows inline.
    /// - Parameter mark: a range of `source` (UTF-16 offsets) to underline and tint, where that keeps formulas whole.
    init(_ source: String, mark: Range<Int>? = nil, showsProblems: Bool = true) {
        self.source = source
        self.mark = mark
        self.showsProblems = showsProblems
    }

    /// A single formula without delimiters.
    init(formula: String, style: MathStyle = .inline, showsProblems: Bool = true) {
        self.init(style == .display ? "$$\(formula)$$" : "$\(formula)$", showsProblems: showsProblems)
    }

    var body: some View {
        let composed = MathTextComposer.compose(source, renderer: renderer, context: context, mark: mark)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(composed.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    text
                        .font(.custom(FontRegistry.textFamily, size: context.fontSize))
                        .fixedSize(horizontal: false, vertical: true)
                case .display(let rendered):
                    DisplayMath(rendered: rendered, fontSize: context.fontSize)
                }
            }
            if showsProblems && !composed.problems.isEmpty {
                MathProblemsCaption(problems: composed.problems)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: composed.accessibilityText))
    }
}

extension View {
    /// Math in notes and captions, set smaller than the steps around it.
    func captionMath() -> some View {
        modifier(CaptionMath())
    }
}

private struct CaptionMath: ViewModifier {
    @Environment(\.mathContext) private var math

    func body(content: Content) -> some View {
        var smaller = math
        smaller.fontSize = math.fontSize * 0.8
        return content.environment(\.mathContext, smaller)
    }
}

#if DEBUG
#Preview("Proof steps through MathText", traits: .fixture) {
    @Previewable @Query(sort: \Step.index) var steps: [Step]
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(steps) { step in
                MathText("\(step.index). " + step.textLaTeX)
            }
            MathText(#"Display: $$\sum_{k=0}^{n} \binom{n}{k} = 2^n$$ and a broken one: $\frac{a$."#)
        }
        .padding()
    }
    .frame(width: 640, height: 900)
}
#endif

/// A display formula on its own centred line.
private struct DisplayMath: View {
    let rendered: RenderedMath
    let fontSize: Double

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            switch rendered {
            case .image(let image):
                Image(nsImage: image.image)
                    .renderingMode(.template)
                    .frame(width: image.size.width, height: image.size.height)
            case .typographic, .source:
                MathTextComposer.inline(rendered, fontSize: fontSize)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// Why formulas were shown as source.
struct MathProblemsCaption: View {
    let problems: [SourceChip]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(problems, id: \.self) { chip in
                Label {
                    Text(verbatim: "Shown as source: \(chip.message)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(ColorToken.refuted.color)
                .help(chip.latex)
            }
        }
    }
}
