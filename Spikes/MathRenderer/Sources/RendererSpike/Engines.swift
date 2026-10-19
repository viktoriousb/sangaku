import AppKit
import SwiftUI

/// A typeset formula: metrics in points and a vector drawing. `draw` paints into a y-down context whose
/// origin is the box's top-left corner; the baseline is at y = ascent.
struct MathBox {
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let draw: (CGContext) -> Void
}

/// One typesetting approach under test.
protocol MathEngine: AnyObject {
    var name: String { get }
    /// Typesets `tex`, or returns the engine's error message.
    func layout(_ tex: String, display: Bool) -> Result<MathBox, EngineError>
}

struct EngineError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Turns any engine's boxes into template images placed inline in SwiftUI `Text`.
final class InlineMath {
    let engine: MathEngine
    private var cache: [String: SwiftMathRenderer.Rendered] = [:]
    var useCache = true

    init(engine: MathEngine) { self.engine = engine }

    /// `salt` makes the cache key unique per row, simulating a thread whose formulas never repeat.
    func rendered(_ tex: String, display: Bool = false, salt: Int = 0) -> SwiftMathRenderer.Rendered? {
        let key = (display ? "D:" : "T:") + tex + "#\(salt)"
        if useCache, let hit = cache[key] { return hit }
        guard case .success(let box) = engine.layout(tex, display: display) else { return nil }
        let image = NSImage(size: NSSize(width: max(1, ceil(box.width)), height: max(1, ceil(box.ascent + box.descent))),
                            flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            box.draw(context)
            return true
        }
        image.isTemplate = true
        let rendered = SwiftMathRenderer.Rendered(image: image, descent: box.descent)
        if useCache { cache[key] = rendered }
        return rendered
    }

    func paragraph(_ prose: String, salt: Int = 0) -> Text {
        var text = Text("")
        let joiner = "\u{2060}"
        for segment in Corpus.segments(prose) {
            switch segment {
            case .text(var s):
                if let first = s.first, !first.isWhitespace { s = joiner + s }
                if let last = s.last, !last.isWhitespace { s += joiner }
                text = text + Text(s)
            case .math(let tex):
                if let r = rendered(tex, salt: salt) {
                    text = text + Text(Image(nsImage: r.image).renderingMode(.template)).baselineOffset(-r.descent)
                } else {
                    text = text + Text(tex).foregroundStyle(.red)
                }
            }
        }
        return text
    }
}

struct EngineRow: View {
    let math: InlineMath
    let prose: String
    var salt = 0

    var body: some View {
        math.paragraph(prose, salt: salt)
            .font(.custom("STIX Two Text", size: 16))
            .foregroundStyle(Color(red: 0x16 / 255, green: 0x18 / 255, blue: 0x1D / 255))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0.92)).frame(height: 1) }
    }
}
