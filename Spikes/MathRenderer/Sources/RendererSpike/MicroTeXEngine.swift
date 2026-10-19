import AppKit
import CMicroTeX
import CoreText

// MicroTeX calls back into these C functions. They run synchronously on the thread that calls
// `microtex_getDrawingData`, which in the spike is always the main thread.
nonisolated(unsafe) private var textLayouts: [UInt32: (line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat)] = [:]
nonisolated(unsafe) private var nextTextLayout: UInt32 = 1
nonisolated(unsafe) private var glyphPaths: [Int32: CGPath] = [:]
/// Set when MicroTeX falls back to typesetting raw source (an unknown command or environment) as text.
nonisolated(unsafe) private var sawRawSource = false

private let createTextLayout: CBCreateTextLayout = { text, desc in
    guard let text, let desc else { return 0 }
    let d = desc.pointee
    if strchr(text, 92) != nil { sawRawSource = true } // a backslash in a text run means unparsed source
    var traits: CTFontSymbolicTraits = []
    if d.isBold { traits.insert(.traitBold) }
    if d.isItalic { traits.insert(.traitItalic) }
    let family = d.isMonospace ? "Menlo" : d.isSansSerif ? "Helvetica Neue" : "STIX Two Text"
    let base = CTFontCreateWithName(family as CFString, CGFloat(d.fontSize), nil)
    let font = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
    let attributed = NSAttributedString(string: String(cString: text), attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let id = nextTextLayout
    nextTextLayout += 1
    textLayouts[id] = (line, CGFloat(width), ascent, descent)
    return id
}

private let getTextLayoutBounds: CBGetTextLayoutBounds = { id, bounds in
    guard let bounds, let layout = textLayouts[id] else { return }
    bounds.pointee = TextLayoutBounds(width: Float(layout.width), height: Float(layout.ascent + layout.descent),
                                      ascent: Float(layout.ascent))
}

private let releaseTextLayout: CBReleaseTextLayout = { _ in
    // Kept: recorded drawings still reference the line. A real implementation would refcount.
}

private let isPathExists: CBIsPathExists = { id in
    id >= 0 && glyphPaths[id] != nil
}

/// Candidate: MicroTeX, a C++ port of JLaTeXMath with OpenType MATH fonts. It emits drawing commands,
/// which are replayed here into CoreGraphics. Glyph outlines arrive once per glyph id and are cached.
final class MicroTeXEngine: MathEngine {
    let name: String
    let fontSize: CGFloat
    let macros: MacroSet
    private let precision: Float = 8

    init(fontFile: String, macros: MacroSet, fontSize: CGFloat = 16) throws {
        self.fontSize = fontSize
        self.macros = macros
        guard let url = Bundle.module.url(forResource: fontFile, withExtension: "clm2", subdirectory: "microtex"),
              let data = try? Data(contentsOf: url) else {
            throw SpikeError.missingResource(fontFile)
        }
        microtex_registerCallbacks(createTextLayout, getTextLayoutBounds, releaseTextLayout, isPathExists)
        let meta = data.withUnsafeBytes { raw in
            microtex_init(UInt(data.count), raw.bindMemory(to: UInt8.self).baseAddress)
        }
        guard let meta else { throw SpikeError.javascript("microtex_init failed") }
        let fontName = String(cString: microtex_getFontName(meta))
        microtex_setDefaultMathFont(fontName)
        microtex_releaseFontMeta(meta)
        microtex_setRenderGlyphUsePath(true)
        name = "MicroTeX (\(fontName))"
    }

    func layout(_ tex: String, display: Bool) -> Result<MathBox, EngineError> {
        // MicroTeX implements \newcommand; expanding first keeps all engines on the same footing.
        let source = Self.fixups(macros.expand(tex))
        sawRawSource = false
        var error = [CChar](repeating: 0, count: 256)
        guard let render = microtex_spike_tryParse(source, Float(fontSize), display, &error, 256) else {
            return .failure(EngineError(message: String(cString: error)))
        }
        defer { microtex_deleteRender(render) }
        // Sizes come back as whole pixels, so measure at 8× and scale down for sub-point baselines.
        microtex_setRenderTextSize(render, Float(fontSize) * precision)
        let width = CGFloat(microtex_getRenderWidth(render)) / CGFloat(precision)
        let total = CGFloat(microtex_getRenderHeight(render)) / CGFloat(precision)
        let depth = CGFloat(microtex_getRenderDepth(render)) / CGFloat(precision)
        microtex_setRenderTextSize(render, Float(fontSize))
        guard let data = microtex_getDrawingData(render, 0, 0) else {
            return .failure(EngineError(message: "no drawing data"))
        }
        defer { microtex_freeDrawingData(data) }
        if sawRawSource { return .failure(EngineError(message: "unsupported command (rendered as raw source)")) }
        let ops = Self.decode(data)
        return .success(MathBox(width: width, ascent: total - depth, descent: depth) { context in
            Self.replay(ops, in: context)
        })
    }

    /// TeX-faithful rewrites for constructs MicroTeX spaces differently from amsmath.
    static func fixups(_ tex: String) -> String {
        var s = tex
        let rewrites: [(String, String)] = [
            // amsmath inline \pmod: \mkern8mu(\operator@font mod\mkern6mu #1)
            (#"\\pmod\{([^{}]*)\}"#, #"\\,\\;(\\mathrm{mod}\\,\\,$1)"#),
            (#"\\bmod(?![A-Za-z])"#, #"\\mathbin{\\mathrm{mod}}"#),
            (#"\\operatorname\*\{([^{}]*)\}"#, #"\\mathop{\\mathrm{$1}}\\limits"#),
            // TeX's / is an ordinary symbol; MicroTeX spaces it like a binary operator.
            (#"(?<!\\)/"#, #"{/}"#),
        ]
        for (pattern, template) in rewrites {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }

    enum Op {
        case color(UInt32)
        case lineWidth(CGFloat)
        case translate(CGFloat, CGFloat)
        case scale(CGFloat, CGFloat)
        case rotate(CGFloat, CGFloat, CGFloat)
        case reset
        case fill(CGPath)
        case line(CGPoint, CGPoint)
        case rect(CGRect, filled: Bool)
        case text(CTLine, CGPoint)
    }

    /// Decodes MicroTeX's command buffer (format documented in lib/wrapper/cwrapper.h).
    static func decode(_ data: UnsafeMutableRawPointer) -> [Op] {
        let length = Int(data.loadUnaligned(as: UInt32.self))
        var i = 4
        func f32() -> CGFloat { defer { i += 4 }; return CGFloat(data.loadUnaligned(fromByteOffset: i, as: Float32.self)) }
        func u32() -> UInt32 { defer { i += 4 }; return data.loadUnaligned(fromByteOffset: i, as: UInt32.self) }
        func i32() -> Int32 { defer { i += 4 }; return data.loadUnaligned(fromByteOffset: i, as: Int32.self) }
        func u16() -> UInt16 { defer { i += 2 }; return data.loadUnaligned(fromByteOffset: i, as: UInt16.self) }
        func u8() -> UInt8 { defer { i += 1 }; return data.loadUnaligned(fromByteOffset: i, as: UInt8.self) }
        var ops: [Op] = []
        var path: CGMutablePath?
        while i < length {
            switch u8() {
            case 0: ops.append(.color(u32()))
            case 1: let w = f32(); _ = f32(); _ = u32(); _ = u32(); ops.append(.lineWidth(w))
            case 2: _ = u8()
            case 3: while data.loadUnaligned(fromByteOffset: i, as: UInt8.self) != 0 { i += 1 }; i += 1
            case 4: _ = f32()
            case 5: ops.append(.translate(f32(), f32()))
            case 6: ops.append(.scale(f32(), f32()))
            case 7: ops.append(.rotate(f32(), f32(), f32()))
            case 8: ops.append(.reset)
            case 9: _ = u16(); _ = f32(); _ = f32() // glyph by typeface; unused with path rendering
            case 10: _ = i32(); path = CGMutablePath()
            case 11: path?.move(to: CGPoint(x: f32(), y: f32()))
            case 12: path?.addLine(to: CGPoint(x: f32(), y: f32()))
            case 13:
                let c1 = CGPoint(x: f32(), y: f32()), c2 = CGPoint(x: f32(), y: f32()), p = CGPoint(x: f32(), y: f32())
                path?.addCurve(to: p, control1: c1, control2: c2)
            case 14:
                let c = CGPoint(x: f32(), y: f32()), p = CGPoint(x: f32(), y: f32())
                path?.addQuadCurve(to: p, control: c)
            case 15: path?.closeSubpath()
            case 16:
                let id = i32()
                if let built = path, !built.isEmpty {
                    if id >= 0 { glyphPaths[id] = built }
                    ops.append(.fill(built))
                } else if let cached = glyphPaths[id] {
                    ops.append(.fill(cached))
                }
                path = nil
            case 17: ops.append(.line(CGPoint(x: f32(), y: f32()), CGPoint(x: f32(), y: f32())))
            case 18: ops.append(.rect(CGRect(x: f32(), y: f32(), width: f32(), height: f32()), filled: false))
            case 19: ops.append(.rect(CGRect(x: f32(), y: f32(), width: f32(), height: f32()), filled: true))
            case 20: let r = CGRect(x: f32(), y: f32(), width: f32(), height: f32()); _ = f32(); _ = f32(); ops.append(.rect(r, filled: false))
            case 21: let r = CGRect(x: f32(), y: f32(), width: f32(), height: f32()); _ = f32(); _ = f32(); ops.append(.rect(r, filled: true))
            case 22:
                let id = u32(), p = CGPoint(x: f32(), y: f32())
                if let layout = textLayouts[id] { ops.append(.text(layout.line, p)) }
            default:
                return ops // unknown command: stop rather than misread the stream
            }
        }
        return ops
    }

    /// Replays into a y-down context. Colour comes from the context so template tinting works.
    static func replay(_ ops: [Op], in context: CGContext) {
        context.saveGState()
        let base = context.ctm
        context.setFillColor(NSColor.black.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        for op in ops {
            switch op {
            case .color: break
            case .lineWidth(let w): context.setLineWidth(w)
            case .translate(let dx, let dy): context.translateBy(x: dx, y: dy)
            case .scale(let sx, let sy): context.scaleBy(x: sx, y: sy)
            case .rotate(let a, let px, let py):
                context.translateBy(x: px, y: py); context.rotate(by: a); context.translateBy(x: -px, y: -py)
            case .reset:
                context.concatenate(context.ctm.inverted()); context.concatenate(base)
            case .fill(let path): context.addPath(path); context.fillPath()
            case .line(let a, let b): context.move(to: a); context.addLine(to: b); context.strokePath()
            case .rect(let r, let filled): if filled { context.fill(r) } else { context.stroke(r) }
            case .text(let line, let p):
                context.saveGState()
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = p
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }
        context.restoreGState()
    }
}
