import CoreGraphics
import CoreText
import Foundation

/// One drawing command from MicroTeX, in its y-down coordinate space. `CGPath` and `CTLine` are immutable,
/// so ops can be drawn from whatever thread AppKit renders an image on.
nonisolated enum DrawOp: @unchecked Sendable {
    case lineWidth(Double)
    case translate(Double, Double)
    case scale(Double, Double)
    case rotate(angle: Double, pivotX: Double, pivotY: Double)
    case resetTransform
    case fill(CGPath)
    case line(CGPoint, CGPoint)
    case rect(CGRect, filled: Bool)
    case text(CTLine, CGPoint)
}

nonisolated struct DrawOpDecodingError: Error, Hashable, Sendable {
    var message: String
}

/// Decodes MicroTeX's command buffer (format documented in `Vendor/MicroTeX/.../wrapper/cwrapper.h`).
///
/// Anything unexpected is an error, never a shorter drawing: a formula with missing parts would be wrong math
/// that looks right (invariant 16).
nonisolated enum DrawOpDecoder {
    /// - Parameters:
    ///   - bytes: the whole buffer, starting with its own 4-byte length.
    ///   - glyphPaths: cache of glyph outlines by path id; MicroTeX sends an outline only the first time.
    ///   - textLine: resolves a text-layout id created through the text-layout callback.
    static func decode(_ bytes: UnsafeRawBufferPointer, glyphPaths: inout [Int32: CGPath],
                       textLine: (UInt32) -> CTLine?) throws(DrawOpDecodingError) -> [DrawOp] {
        var reader = Reader(bytes: bytes)
        let length = try Int(reader.u32())
        guard length <= bytes.count else { throw DrawOpDecodingError(message: "buffer shorter than its stated length") }
        var ops: [DrawOp] = []
        var path: CGMutablePath?
        var pathID: Int32 = -1
        while reader.offset < length {
            let command = try reader.u8()
            switch command {
            case 0: _ = try reader.u32() // colour: ignored, so template tinting decides the ink
            case 1:
                let width = try reader.f32()
                _ = try reader.f32(); _ = try reader.u32(); _ = try reader.u32()
                ops.append(.lineWidth(width))
            case 2: _ = try reader.u8() // dash flag; MicroTeX does not send a pattern
            case 3: try reader.skipCString() // font family
            case 4: _ = try reader.f32() // font size
            case 5: ops.append(.translate(try reader.f32(), try reader.f32()))
            case 6: ops.append(.scale(try reader.f32(), try reader.f32()))
            case 7: ops.append(.rotate(angle: try reader.f32(), pivotX: try reader.f32(), pivotY: try reader.f32()))
            case 8: ops.append(.resetTransform)
            case 9:
                throw DrawOpDecodingError(message: "glyph drawn by typeface; sangaku renders glyphs as paths only")
            case 10:
                pathID = try reader.i32()
                path = CGMutablePath()
            case 11: path?.move(to: CGPoint(x: try reader.f32(), y: try reader.f32()))
            case 12: path?.addLine(to: CGPoint(x: try reader.f32(), y: try reader.f32()))
            case 13:
                let c1 = CGPoint(x: try reader.f32(), y: try reader.f32())
                let c2 = CGPoint(x: try reader.f32(), y: try reader.f32())
                let p = CGPoint(x: try reader.f32(), y: try reader.f32())
                path?.addCurve(to: p, control1: c1, control2: c2)
            case 14:
                let c = CGPoint(x: try reader.f32(), y: try reader.f32())
                let p = CGPoint(x: try reader.f32(), y: try reader.f32())
                path?.addQuadCurve(to: p, control: c)
            case 15: path?.closeSubpath()
            case 16:
                let id = try reader.i32()
                if let built = path, !built.isEmpty {
                    if id >= 0 { glyphPaths[id] = built.copy() }
                    ops.append(.fill(built))
                } else if let cached = glyphPaths[id] {
                    ops.append(.fill(cached))
                } else {
                    throw DrawOpDecodingError(message: "fill of unknown path \(id) (begun as \(pathID))")
                }
                path = nil
            case 17:
                ops.append(.line(CGPoint(x: try reader.f32(), y: try reader.f32()), CGPoint(x: try reader.f32(), y: try reader.f32())))
            case 18, 19:
                let r = CGRect(x: try reader.f32(), y: try reader.f32(), width: try reader.f32(), height: try reader.f32())
                ops.append(.rect(r, filled: command == 19))
            case 20, 21:
                let r = CGRect(x: try reader.f32(), y: try reader.f32(), width: try reader.f32(), height: try reader.f32())
                _ = try reader.f32(); _ = try reader.f32() // corner radii: MicroTeX uses them only for \fbox variants
                ops.append(.rect(r, filled: command == 21))
            case 22:
                let id = try reader.u32()
                let point = CGPoint(x: try reader.f32(), y: try reader.f32())
                guard let line = textLine(id) else { throw DrawOpDecodingError(message: "unknown text layout \(id)") }
                ops.append(.text(line, point))
            default:
                throw DrawOpDecodingError(message: "unknown drawing command \(command)")
            }
        }
        return ops
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        var offset = 0

        mutating func take<T>(_ type: T.Type) throws(DrawOpDecodingError) -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= bytes.count else { throw DrawOpDecodingError(message: "truncated drawing data") }
            defer { offset += size }
            return bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
        }

        mutating func u8() throws(DrawOpDecodingError) -> UInt8 { try take(UInt8.self) }
        mutating func u32() throws(DrawOpDecodingError) -> UInt32 { try take(UInt32.self) }
        mutating func i32() throws(DrawOpDecodingError) -> Int32 { try take(Int32.self) }
        mutating func f32() throws(DrawOpDecodingError) -> Double { Double(try take(Float32.self)) }

        mutating func skipCString() throws(DrawOpDecodingError) {
            while true {
                if try u8() == 0 { return }
            }
        }
    }
}

/// Replays decoded commands into a y-down context. Ink comes from the context's fill and stroke colours.
nonisolated enum DrawOpReplay {
    static func draw(_ ops: [DrawOp], in context: CGContext) {
        context.saveGState()
        let base = context.ctm
        for op in ops {
            switch op {
            case .lineWidth(let w):
                context.setLineWidth(w)
            case .translate(let dx, let dy):
                context.translateBy(x: dx, y: dy)
            case .scale(let sx, let sy):
                context.scaleBy(x: sx, y: sy)
            case .rotate(let angle, let px, let py):
                context.translateBy(x: px, y: py)
                context.rotate(by: angle)
                context.translateBy(x: -px, y: -py)
            case .resetTransform:
                context.concatenate(context.ctm.inverted())
                context.concatenate(base)
            case .fill(let path):
                context.addPath(path)
                context.fillPath()
            case .line(let a, let b):
                context.move(to: a)
                context.addLine(to: b)
                context.strokePath()
            case .rect(let r, let filled):
                if filled { context.fill(r) } else { context.stroke(r) }
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
