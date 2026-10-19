import AppKit
@preconcurrency import SwiftMath
import SwiftUI

/// Option (a): SwiftMath. Each formula becomes a vector-drawn NSImage plus its descent,
/// so it can sit inline in a SwiftUI `Text` on the prose baseline.
final class SwiftMathRenderer {
    struct Rendered {
        let image: NSImage
        let descent: CGFloat
    }

    let macros: MacroSet
    let fontSize: CGFloat
    var useCache = true
    private var cache: [String: Rendered] = [:]

    init(macros: MacroSet, fontSize: CGFloat = 16) {
        self.macros = macros
        self.fontSize = fontSize
    }

    /// Whether SwiftMath parses `tex`, after user-macro expansion and optionally the fallbacks.
    func parseError(_ tex: String, fallbacks: Bool) -> String? {
        var error: NSError?
        let expanded = macros.expand(tex, swiftMathFallbacks: fallbacks)
        let list = MTMathListBuilder.build(fromString: expanded, error: &error)
        if let error { return error.localizedDescription }
        return list == nil ? "no output" : nil
    }

    func render(_ tex: String, display: Bool = false) -> Rendered? {
        let key = (display ? "D:" : "T:") + tex
        if useCache, let hit = cache[key] { return hit }
        let label = MTMathUILabel()
        label.labelMode = display ? .display : .text
        label.font = MTFontManager.manager.xitsFont(withSize: fontSize)
        label.textColor = .black
        label.latex = macros.expand(tex, swiftMathFallbacks: true)
        guard label.error == nil else { return nil }
        label.frame.size = label.fittingSize  // macOS: intrinsicContentSize is not overridden
        label.layout()
        guard let list = label.displayList else { return nil }
        let ascent = list.ascent, descent = list.descent
        let size = NSSize(width: ceil(list.width), height: ceil(ascent + descent))
        // With the frame at its intrinsic size, the label's layout puts the baseline at y = descent.
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            list.draw(context)
            return true
        }
        let rendered = Rendered(image: image, descent: descent)
        if useCache { cache[key] = rendered }
        return rendered
    }

    /// A prose paragraph with inline formulas, laid out and wrapped by SwiftUI `Text`.
    func paragraph(_ prose: String) -> Text {
        var text = Text("")
        for segment in Corpus.segments(prose) {
            switch segment {
            case .text(let s):
                text = text + Text(s)
            case .math(let tex):
                if let r = render(tex) {
                    text = text + Text(Image(nsImage: r.image)).baselineOffset(-r.descent)
                } else {
                    text = text + Text(tex).foregroundStyle(.red)
                }
            }
        }
        return text
    }
}

/// One proof-step row, as the thread would show it.
struct SwiftMathRow: View {
    let renderer: SwiftMathRenderer
    let prose: String

    var body: some View {
        renderer.paragraph(prose)
            .font(.custom("STIX Two Text", size: 16))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.92)).frame(height: 1) }
    }
}
