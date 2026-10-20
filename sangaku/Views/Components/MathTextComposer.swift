import SwiftUI

/// Prose with math, composed for display. The only place that builds `Text` from rendered math.
struct ComposedMath {
    enum Block {
        case paragraph(Text)
        case display(RenderedMath)
    }

    var blocks: [Block] = []
    /// Formulas shown as source, deduplicated, for the caption under the paragraph.
    var problems: [SourceChip] = []
    /// What VoiceOver reads: prose, tier-1 math as text, everything else as its LaTeX source.
    var accessibilityText = ""
}

enum MathTextComposer {
    /// What VoiceOver says for prose with math: formulas as `MathText` speaks them, for a label on a view that draws
    /// the text itself.
    static func spoken(_ source: String, renderer: MathRenderer?, context: MathContext) -> String {
        compose(source, renderer: renderer, context: context).accessibilityText
    }

    /// `mark` (UTF-16 offsets into `source`) is underlined and tinted where it can be: in prose and in formulas set as
    /// text. A mark that would cut a formula is not drawn; the caller says it in words as well.
    static func compose(_ source: String, renderer: MathRenderer?, context: MathContext,
                        mark: Range<Int>? = nil) -> ComposedMath {
        var composed = ComposedMath()
        var parts: [Text] = []
        let joiner = TypographicMath.wordJoiner

        func note(_ chip: SourceChip) {
            if !composed.problems.contains(chip) { composed.problems.append(chip) }
        }
        func flushParagraph() {
            if !parts.isEmpty { composed.blocks.append(.paragraph(join(parts))); parts = [] }
        }

        let segments = (pieces(source, mark: mark) ?? [(source, false)]).flatMap { piece, marked in
            ProseSegmenter.segments(piece).map { (segment: $0, marked: marked) }
        }
        for (segment, marked) in segments {
            switch segment {
            case .text(var prose):
                composed.accessibilityText += prose
                // Hold math to adjacent punctuation ("$p$," or "$3$-subgroup"): no line break between them.
                if let first = prose.first, !first.isWhitespace { prose = joiner + prose }
                if let last = prose.last, !last.isWhitespace { prose += joiner }
                if marked {
                    var attributed = AttributedString(prose)
                    attributed.underlineStyle = .single
                    attributed.backgroundColor = ColorToken.delicateFill.color
                    parts.append(Text(attributed))
                } else {
                    parts.append(Text(verbatim: prose))
                }
            case .math(let latex, .inline):
                let rendered = render(latex, renderer: renderer, context: context, style: .inline)
                if case .source(let chip) = rendered { note(chip) }
                composed.accessibilityText += spoken(rendered, latex: latex)
                let text = inline(rendered, fontSize: context.fontSize)
                parts.append(marked ? text.underline() : text)
            case .math(let latex, .display):
                flushParagraph()
                let rendered = render(latex, renderer: renderer, context: context, style: .display)
                if case .source(let chip) = rendered { note(chip) }
                composed.accessibilityText += " " + spoken(rendered, latex: latex) + " "
                composed.blocks.append(.display(rendered))
            case .unterminated(let rest):
                let chip = SourceChip(latex: rest, message: "Math is opened but never closed")
                note(chip)
                composed.accessibilityText += spoken(.source(chip), latex: rest)
                parts.append(inline(.source(chip), fontSize: context.fontSize))
            }
        }
        flushParagraph()
        return composed
    }

    /// The source cut at a mark (`KeyPhrase.pieces`), flagged marked or not. Nil where the cut would break a formula:
    /// the mark is not drawn.
    static func pieces(_ source: String, mark: Range<Int>?) -> [(String, Bool)]? {
        guard let mark, let pieces = KeyPhrase.pieces(source, mark: mark) else { return nil }
        return [(pieces[0], false), (pieces[1], true), (pieces[2], false)]
    }

    private static func render(_ latex: String, renderer: MathRenderer?, context: MathContext, style: MathStyle) -> RenderedMath {
        guard let renderer else {
            return .source(SourceChip(latex: latex, message: "No math renderer in the environment"))
        }
        return renderer.render(latex, context: context, style: style)
    }

    /// What VoiceOver reads for one formula. Scripts are spoken ("n sub p", "p superscript 2") so `p^2q` is not
    /// heard as "p2q"; a formula shown as source says so.
    static func spoken(_ rendered: RenderedMath, latex: String) -> String {
        switch rendered {
        case .typographic(let runs):
            var out = ""
            var previous = MathRun.Script.base
            for run in runs {
                if run.script != previous {
                    switch run.script {
                    case .base: out += " "
                    case .subscript: out += " sub "
                    case .superscript: out += " superscript "
                    }
                    previous = run.script
                }
                out += run.text
            }
            return out.replacing(TypographicMath.wordJoiner, with: "")
        case .image:
            return latex
        case .source(let chip):
            return "formula shown as source, \(chip.latex), because: \(chip.message)"
        }
    }

    /// One formula as inline `Text`.
    static func inline(_ rendered: RenderedMath, fontSize: Double) -> Text {
        switch rendered {
        case .typographic(let runs):
            return join(runs.map { run($0, fontSize: fontSize) })
        case .image(let image):
            return Text(Image(nsImage: image.image).renderingMode(.template)).baselineOffset(-image.descent)
        case .source(let chip):
            var attributed = AttributedString("⚠\u{FE0E} " + chip.latex)
            attributed.font = .system(size: fontSize * 0.8, design: .monospaced)
            attributed.foregroundColor = ColorToken.refuted.color
            attributed.backgroundColor = ColorToken.refutedFill.color
            return Text(attributed)
        }
    }

    private static func run(_ run: MathRun, fontSize: Double) -> Text {
        let size = run.script == .base ? fontSize : fontSize * 0.7
        let family = run.face == .math ? FontRegistry.mathFamily : FontRegistry.textFamily
        var text = Text(verbatim: run.text).font(.custom(family, size: size))
        if run.italic { text = text.italic() }
        switch run.script {
        case .base: break
        case .superscript: text = text.baselineOffset(fontSize * 0.36)
        case .subscript: text = text.baselineOffset(-fontSize * 0.18)
        }
        return text
    }

    /// Joins `Text` by interpolation (`+` on `Text` is deprecated).
    static func join(_ parts: [Text]) -> Text {
        guard var result = parts.first else { return Text(verbatim: "") }
        for part in parts.dropFirst() {
            result = Text("\(result)\(part)")
        }
        return result
    }
}
