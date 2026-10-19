import AppKit
import CoreText
import JavaScriptCore

/// Candidate: MathJax 4 with the STIX Two font, running in JavaScriptCore (no WebKit, no DOM). The bundle
/// returns the SVG output flattened into path, rect, line and text ops, which are drawn with CoreGraphics.
final class MathJaxEngine: MathEngine {
    let name = "MathJax 4 (STIX Two) in JavaScriptCore"
    let fontSize: CGFloat
    private let context: JSContext
    private let render: JSValue
    private var paths: [String: CGPath] = [:]

    init(macros: MacroSet, fontSize: CGFloat = 16) throws {
        self.fontSize = fontSize
        guard let url = Bundle.module.url(forResource: "mathjax-stix2", withExtension: "js", subdirectory: "mathjax"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw SpikeError.missingResource("mathjax-stix2.js")
        }
        guard let context = JSContext() else { throw SpikeError.javascript("no JSContext") }
        self.context = context
        context.evaluateScript("var console = { log() {}, warn() {}, error() {} };")
        context.evaluateScript(source)
        if let e = context.exception { throw SpikeError.javascript("bundle: \(e)") }
        var configured: [String: Any] = [:]
        for (name, macro) in macros.macros {
            configured[name] = macro.arity > 0 ? [macro.body, macro.arity] : macro.body
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: configured), encoding: .utf8)!
        context.objectForKeyedSubscript("mjInit").call(withArguments: [json])
        if let e = context.exception { throw SpikeError.javascript("init: \(e)") }
        guard let fn = context.objectForKeyedSubscript("mjRender"), !fn.isUndefined else {
            throw SpikeError.javascript("mjRender missing")
        }
        render = fn
    }

    private enum Op {
        case fill(CGPath, CGAffineTransform)
        case rect(CGRect, CGAffineTransform)
        case line(CGPoint, CGPoint, CGFloat, CGAffineTransform)
        case text(CTLine, CGAffineTransform)
    }

    func layout(_ tex: String, display: Bool) -> Result<MathBox, EngineError> {
        guard let json = render.call(withArguments: [tex, display])?.toString(),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return .failure(EngineError(message: "no output"))
        }
        if let error = object["error"] as? String { return .failure(EngineError(message: error)) }
        guard let vb = object["vb"] as? [Double], vb.count == 4, let raw = object["ops"] as? [[Any]] else {
            return .failure(EngineError(message: "bad output"))
        }
        func matrix(_ a: [Any], from i: Int) -> CGAffineTransform {
            let m = a[i...].prefix(6).map { CGFloat(($0 as? Double) ?? 0) }
            return CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
        }
        func number(_ v: Any) -> CGFloat { CGFloat((v as? Double) ?? 0) }
        var ops: [Op] = []
        ops.reserveCapacity(raw.count)
        for a in raw {
            guard let kind = a.first as? String else { continue }
            switch kind {
            case "p":
                guard let d = a[1] as? String else { continue }
                let path: CGPath
                if let cached = paths[d] { path = cached } else { path = SVGPath.parse(d); paths[d] = path }
                ops.append(.fill(path, matrix(a, from: 2)))
            case "r":
                ops.append(.rect(CGRect(x: number(a[1]), y: number(a[2]), width: number(a[3]), height: number(a[4])), matrix(a, from: 5)))
            case "l":
                ops.append(.line(CGPoint(x: number(a[1]), y: number(a[2])), CGPoint(x: number(a[3]), y: number(a[4])),
                                 number(a[5]), matrix(a, from: 6)))
            case "t":
                let text = (a[1] as? String) ?? ""
                let size = number(a[2])
                let italic = (a[4] as? String) == "italic", bold = (a[5] as? String) == "bold"
                var traits: CTFontSymbolicTraits = []
                if italic { traits.insert(.traitItalic) }
                if bold { traits.insert(.traitBold) }
                let base = CTFontCreateWithName("STIX Two Text" as CFString, size, nil)
                let font = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]))
                ops.append(.text(line, matrix(a, from: 6)))
            default:
                continue
            }
        }
        let scale = fontSize / 1000
        let (minX, minY, w, h) = (CGFloat(vb[0]), CGFloat(vb[1]), CGFloat(vb[2]), CGFloat(vb[3]))
        return .success(MathBox(width: w * scale, ascent: -minY * scale, descent: (minY + h) * scale) { context in
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -minX, y: -minY)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            for op in ops {
                context.saveGState()
                switch op {
                case .fill(let path, let m):
                    context.concatenate(m); context.addPath(path); context.fillPath()
                case .rect(let r, let m):
                    context.concatenate(m); context.fill(r)
                case .line(let a, let b, let width, let m):
                    context.concatenate(m); context.setLineWidth(width); context.move(to: a); context.addLine(to: b); context.strokePath()
                case .text(let line, let m):
                    context.concatenate(m); context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                    context.textPosition = .zero; CTLineDraw(line, context)
                }
                context.restoreGState()
            }
            context.restoreGState()
        })
    }
}

/// Minimal SVG path-data parser: M L H V C S Q T Z, absolute and relative. Arcs are not used by MathJax glyphs.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Array(d.utf8)[...]
        var command: UInt8 = UInt8(ascii: "M")
        var current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        func skip() { while let c = scanner.first, c == 32 || c == 44 || c == 10 || c == 9 { scanner.removeFirst() } }
        func number() -> CGFloat? {
            skip()
            var s = ""
            var seenDot = false, seenExp = false
            while let c = scanner.first {
                let ch = Character(UnicodeScalar(c))
                if ch.isNumber { s.append(ch) }
                else if (ch == "-" || ch == "+") && (s.isEmpty || s.last == "e" || s.last == "E") { s.append(ch) }
                else if ch == "." && !seenDot && !seenExp { seenDot = true; s.append(ch) }
                else if (ch == "e" || ch == "E") && !seenExp && !s.isEmpty { seenExp = true; s.append(ch) }
                else { break }
                scanner.removeFirst()
            }
            return s.isEmpty ? nil : Double(s).map { CGFloat($0) }
        }
        func point(_ relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        while true {
            skip()
            guard let c = scanner.first else { break }
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) { command = c; scanner.removeFirst() }
            let rel = command >= 97
            switch Character(UnicodeScalar(command)).uppercased() {
            case "M":
                guard let p = point(rel) else { return path }
                path.move(to: p); current = p; start = p; lastControl = nil
                command = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case "L":
                guard let p = point(rel) else { return path }
                path.addLine(to: p); current = p; lastControl = nil
            case "H":
                guard let x = number() else { return path }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y); path.addLine(to: current); lastControl = nil
            case "V":
                guard let y = number() else { return path }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y); path.addLine(to: current); lastControl = nil
            case "C":
                guard let c1 = point(rel), let c2 = point(rel), let p = point(rel) else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case "S":
                guard let c2 = point(rel), let p = point(rel) else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case "Q":
                guard let c1 = point(rel), let p = point(rel) else { return path }
                path.addQuadCurve(to: p, control: c1); current = p; lastControl = c1
            case "T":
                guard let p = point(rel) else { return path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addQuadCurve(to: p, control: c1); current = p; lastControl = c1
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
                command = UInt8(ascii: "M")
                skip()
                if let c = scanner.first, !((c >= 65 && c <= 90) || (c >= 97 && c <= 122)) { return path }
            default:
                return path
            }
        }
        return path
    }
}
