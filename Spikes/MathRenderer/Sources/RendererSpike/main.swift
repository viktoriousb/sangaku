import AppKit

// Usage: RendererSpike [coverage|images|perf|scroll|raster|engines|engines-noscroll|all] [output folder]
let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "all"
let outDir = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "results", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

struct Report: Codable {
    var coverage: [Coverage.Row]?
    var perf: Perf.Result?
    var scroll: ScrollBench.Result?
    var raster: RasterBench.Result?
    var engines: [EngineBench.Result]?
    var hybrid: [HybridBench.Result]?
}

// Memory mode runs before AppKit starts so each engine is measured in a fresh process.
if mode == "memory", arguments.count > 2 {
    let base = footprintMB()
    let macros = MacroSet(preamble: Corpus.preamble)
    let t0 = now()
    let engine: MathEngine
    switch arguments[2] {
    case "swiftmath-compat": engine = SwiftMathEngine(macros: macros, compat: true)
    case "microtex-xits": engine = try! MicroTeXEngine(fontFile: "XITSMath-Regular", macros: macros)
    case "mathjax": engine = try! MathJaxEngine(macros: macros)
    default: fatalError("unknown engine")
    }
    let initMs = now() - t0
    _ = engine.layout(#"n_p \equiv 1 \pmod{p}"#, display: false)
    let firstMs = now() - t0
    let afterInit = footprintMB() - base
    let formulas = Corpus.rows(200).flatMap { Corpus.segments($0).compactMap { if case .math(let t) = $0 { t } else { nil } } }
        + Corpus.expressions.map(\.tex)
    var boxes: [MathBox] = []
    for f in formulas { if case .success(let b) = engine.layout(f, display: false) { boxes.append(b) } }
    let afterLayout = footprintMB() - base
    let ctx = CGContext(data: nil, width: 1600, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: 200); ctx.scaleBy(x: 2, y: -2)
    for b in boxes { b.draw(ctx) }
    let afterDraw = footprintMB() - base
    print(String(format: "%@: init %.1f ms, first formula ready %.1f ms after start; memory +%.1f MB after init, +%.1f MB after %d layouts, +%.1f MB after drawing",
                 engine.name, initMs, firstMs, afterInit, afterLayout, boxes.count, afterDraw))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(["scroll", "raster", "engines", "hybrid", "all"].contains(mode) ? .regular : .accessory)

Task {
    do {
        let macros = MacroSet(preamble: Corpus.preamble)
        let katex = try KaTeXJS(macros: macros)
        var report = Report()
        if mode == "coverage" || mode == "all" { report.coverage = try Coverage.run(macros: macros, katex: katex, out: outDir) }
        if mode == "images" || mode == "all" { try await Images.run(macros: macros, out: outDir) }
        if mode == "perf" || mode == "all" { report.perf = try await Perf.run(macros: macros, katex: katex, out: outDir) }
        if mode == "scroll" || mode == "all" { report.scroll = try await ScrollBench.run(macros: macros, out: outDir) }
        if mode == "raster" || mode == "all" { report.raster = try await RasterBench.run(macros: macros, out: outDir, scroll: true) }
        if mode.hasPrefix("engines") || mode == "all" {
            let only = arguments.count > 2 ? Set(arguments[2].split(separator: ",").map(String.init)) : nil
            let candidates: [(String, () throws -> MathEngine)] = [
                ("swiftmath", { SwiftMathEngine(macros: macros, compat: false) }),
                ("swiftmath-compat", { SwiftMathEngine(macros: macros, compat: true) }),
                ("microtex-xits", { try MicroTeXEngine(fontFile: "XITSMath-Regular", macros: macros) }),
                ("microtex-stix2", { try MicroTeXEngine(fontFile: "STIXTwoMath", macros: macros) }),
                ("mathjax", { try MathJaxEngine(macros: macros) }),
            ].filter { only == nil || only!.contains($0.0) }
            report.engines = try await EngineBench.run(engines: candidates, out: outDir, scroll: mode == "engines")
        }
        if mode == "compare" { try await CompareSheet.run(macros: macros, out: outDir) }
        if mode.hasPrefix("hybrid") || mode == "all" {
            let candidates: [(String, () throws -> MathEngine)] = [
                ("microtex-xits", { try MicroTeXEngine(fontFile: "XITSMath-Regular", macros: macros) }),
                ("mathjax", { try MathJaxEngine(macros: macros) }),
            ]
            report.hybrid = try await HybridBench.run(engines: candidates, macros: macros, out: outDir, scroll: mode == "hybrid")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outDir.appendingPathComponent("report-\(mode).json"))
    } catch {
        print("ERROR: \(error)")
    }
    exit(0)
}
app.run()
