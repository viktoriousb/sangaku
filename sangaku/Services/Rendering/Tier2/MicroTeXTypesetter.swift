import AppKit
import CoreText
internal import CMicroTeX

/// A formula typeset by MicroTeX: metrics in points and the drawing that produces it.
nonisolated struct TypesetFormula: Sendable {
    let width: Double
    let ascent: Double
    let descent: Double
    let ops: [DrawOp]
}

/// The bridge to MicroTeX. MicroTeX keeps process-global state (fonts, macro tables, callbacks), so there is
/// exactly one typesetter, used only on the main actor. Typesetting is synchronous (about 20 µs per formula),
/// which lets views and the composer preview get results inside `body`.
final class MicroTeXTypesetter {
    static let shared = MicroTeXTypesetter()

    enum State: Equatable {
        case ready(fontName: String)
        case unavailable(String)
    }

    private(set) var state: State
    /// The font data stays alive for the process: MicroTeX may read from it after init.
    private let fontData: Data?
    /// Sizes come back from MicroTeX as whole pixels; measuring at 8× gives baselines to 1/8 pt.
    private let metricScale: Float = 8

    init(fontData: Data? = FontRegistry.microTeXFontData()) {
        self.fontData = fontData
        guard let fontData else {
            state = .unavailable("The MicroTeX math font (XITSMath-Regular.clm2) is missing from the app bundle")
            return
        }
        MicroTeXCallbacks.register()
        var error = [CChar](repeating: 0, count: 512)
        let meta = fontData.withUnsafeBytes { raw in
            microtex_tryInit(UInt(raw.count), raw.bindMemory(to: UInt8.self).baseAddress, &error, Int32(error.count))
        }
        guard let meta else {
            state = .unavailable("MicroTeX could not load its font: \(Self.message(error))")
            return
        }
        let name = String(cString: microtex_getFontName(meta))
        microtex_setDefaultMathFont(name)
        microtex_releaseFontMeta(meta)
        microtex_setRenderGlyphUsePath(true)
        state = .ready(fontName: name)
    }

    func typeset(_ latex: String, fontSize: Double, display: Bool) -> Result<TypesetFormula, MathDiagnostic> {
        guard case .ready = state else {
            if case .unavailable(let reason) = state { return .failure(MathDiagnostic(message: reason)) }
            return .failure(MathDiagnostic(message: "MicroTeX is unavailable"))
        }
        let callbacks = MicroTeXCallbacks.state
        callbacks.beginFormula()
        defer { callbacks.endFormula() }

        var error = [CChar](repeating: 0, count: 512)
        guard let render = microtex_tryParse(latex, Float(fontSize), display, &error, Int32(error.count)) else {
            return .failure(MathDiagnostic(message: Self.message(error)))
        }
        defer { microtex_deleteRender(render) }

        microtex_setRenderTextSize(render, Float(fontSize) * metricScale)
        let scale = Double(metricScale)
        let width = Double(microtex_getRenderWidth(render)) / scale
        let total = Double(microtex_getRenderHeight(render)) / scale
        let depth = Double(microtex_getRenderDepth(render)) / scale
        microtex_setRenderTextSize(render, Float(fontSize))

        guard let data = microtex_tryDrawingData(render, 0, 0, &error, Int32(error.count)) else {
            return .failure(MathDiagnostic(message: Self.message(error)))
        }
        defer { microtex_freeDrawingData(data) }
        // Strict parsing should make this impossible; it stays as a second line of defence.
        if callbacks.sawRawSource {
            return .failure(MathDiagnostic(message: "MicroTeX could not parse part of this formula"))
        }
        let length = Int(data.loadUnaligned(as: UInt32.self))
        do {
            let ops = try DrawOpDecoder.decode(UnsafeRawBufferPointer(start: data, count: length),
                                              glyphPaths: &callbacks.glyphPaths, textLine: { callbacks.line(for: $0) })
            return .success(TypesetFormula(width: width, ascent: total - depth, descent: depth, ops: ops))
        } catch {
            return .failure(MathDiagnostic(message: "MicroTeX drawing data: \(error.message)"))
        }
    }

    private static func message(_ buffer: [CChar]) -> String {
        let text = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return text.isEmpty ? "unknown MicroTeX error" : text
    }
}

/// State behind MicroTeX's C callbacks. C function pointers cannot capture context, so it is a singleton;
/// every callback asserts it runs on the main actor, so a call from anywhere else traps instead of racing.
final class MicroTeXCallbacks {
    static let state = MicroTeXCallbacks()

    private struct Layout {
        let line: CTLine
        let width: Double
        let ascent: Double
        let descent: Double
    }

    private var layouts: [UInt32: Layout] = [:]
    private var nextID: UInt32 = 1
    private(set) var sawRawSource = false
    /// Glyph outlines by MicroTeX path id, for the one font loaded at init. MicroTeX sends an outline only
    /// when `pathExists` says it is not cached yet.
    var glyphPaths: [Int32: CGPath] = [:]

    func beginFormula() { sawRawSource = false }

    /// MicroTeX releases its text layouts when the render is deleted; anything left is dropped here.
    func endFormula() { layouts.removeAll(keepingCapacity: true) }

    func line(for id: UInt32) -> CTLine? { layouts[id]?.line }

    fileprivate func createLayout(_ text: String, _ desc: FontDesc) -> UInt32 {
        // A backslash in a text run means MicroTeX fell back to printing source.
        if text.contains("\\") { sawRawSource = true }
        var traits: CTFontSymbolicTraits = []
        if desc.isBold { traits.insert(.traitBold) }
        if desc.isItalic { traits.insert(.traitItalic) }
        let family = desc.isMonospace ? "Menlo" : desc.isSansSerif ? "Helvetica Neue" : FontRegistry.textFamily
        let base = CTFontCreateWithName(family as CFString, CGFloat(desc.fontSize), nil)
        let font = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let id = nextID
        nextID &+= 1
        layouts[id] = Layout(line: line, width: width, ascent: ascent, descent: descent)
        return id
    }

    fileprivate func bounds(_ id: UInt32) -> TextLayoutBounds {
        guard let layout = layouts[id] else { return TextLayoutBounds(width: 0, height: 0, ascent: 0) }
        // MicroTeX expects the ascent as a negative offset from the baseline (graphic.h: Rect.y).
        return TextLayoutBounds(width: Float(layout.width), height: Float(layout.ascent + layout.descent),
                                ascent: Float(-layout.ascent))
    }

    fileprivate func release(_ id: UInt32) { layouts[id] = nil }

    fileprivate func pathExists(_ id: Int32) -> Bool {
        id >= 0 && glyphPaths[id] != nil
    }

    static func register() {
        microtex_registerCallbacks(createTextLayoutCallback, textLayoutBoundsCallback,
                                   releaseTextLayoutCallback, pathExistsCallback)
    }
}

private let createTextLayoutCallback: CBCreateTextLayout = { text, desc in
    guard let text, let desc else { return 0 }
    let string = String(cString: text)
    let description = desc.pointee
    return MainActor.assumeIsolated { MicroTeXCallbacks.state.createLayout(string, description) }
}

private let textLayoutBoundsCallback: CBGetTextLayoutBounds = { id, bounds in
    guard let bounds else { return }
    bounds.pointee = MainActor.assumeIsolated { MicroTeXCallbacks.state.bounds(id) }
}

private let releaseTextLayoutCallback: CBReleaseTextLayout = { id in
    MainActor.assumeIsolated { MicroTeXCallbacks.state.release(id) }
}

private let pathExistsCallback: CBIsPathExists = { id in
    MainActor.assumeIsolated { MicroTeXCallbacks.state.pathExists(id) }
}
