import AppKit
import SwiftUI

/// Runs every engine through the same measurements.
enum EngineBench {
    struct Result: Codable {
        var name = ""
        var initMs = 0.0
        var initMB = 0.0
        var covered = 0
        var total = 0
        var failures: [String: String] = [:]
        var proseFormulas = 0
        var proseFailures = 0
        var layoutAllMs = 0.0
        var drawAllMs = 0.0
        var afterAllMB = 0.0
        var scroll: FrameStats?

        var line: String {
            String(format: "%@: init %.1f ms (+%.1f MB); coverage %d/%d; prose formulas failing %d/%d; layout 875 %.1f ms (%.0f µs each), draw %.1f ms; footprint +%.1f MB",
                   name, initMs, initMB, covered, total, proseFailures, proseFormulas, layoutAllMs,
                   proseFormulas == 0 ? 0 : 1000 * layoutAllMs / Double(proseFormulas), drawAllMs, afterAllMB)
        }
    }

    static func slug(_ name: String) -> String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .replacingOccurrences(of: "--", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func run(engines: [(String, () throws -> MathEngine)], out: URL, scroll: Bool) async throws -> [Result] {
        var results: [Result] = []
        let rows = Corpus.rows(200)
        let formulas = rows.flatMap { Corpus.segments($0).compactMap { if case .math(let t) = $0 { t } else { nil } } }
        for (label, make) in engines {
            var r = Result()
            let before = footprintMB()
            var t = now()
            let engine: MathEngine
            do { engine = try make() } catch { print("\(label): init failed: \(error)"); continue }
            r.initMs = now() - t
            r.initMB = footprintMB() - before
            r.name = engine.name

            // Coverage over the corpus.
            r.total = Corpus.expressions.count
            for item in Corpus.expressions {
                switch engine.layout(item.tex, display: item.display) {
                case .success: r.covered += 1
                case .failure(let e): r.failures[item.tex] = e.message
                }
            }

            // Layout every formula in 200 rows without a cache, then draw them all.
            r.proseFormulas = formulas.count
            t = now()
            var boxes: [MathBox] = []
            for f in formulas {
                if case .success(let box) = engine.layout(f, display: false) { boxes.append(box) } else { r.proseFailures += 1 }
            }
            r.layoutAllMs = now() - t
            let ctx = CGContext(data: nil, width: 1600, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: 200); ctx.scaleBy(x: 2, y: -2)
            t = now()
            for box in boxes { box.draw(ctx) }
            r.drawAllMs = now() - t

            // Sheets.
            let math = InlineMath(engine: engine)
            let slug = slug(engine.name)
            let prose = ImageRenderer(content:
                VStack(spacing: 0) { ForEach(Array(Corpus.prose.enumerated()), id: \.offset) { EngineRow(math: math, prose: $0.element) } }
                    .frame(width: 640).background(Color.white))
            prose.scale = 2
            if let cg = prose.cgImage, let data = pngData(cg) { try data.write(to: out.appendingPathComponent("engine-\(slug)-prose.png")) }
            let corpus = ImageRenderer(content:
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(Corpus.expressions.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 10) {
                            Text(item.category).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            if let rendered = math.rendered(item.tex, display: item.display) {
                                Image(nsImage: rendered.image).renderingMode(.template).foregroundStyle(.black)
                            } else {
                                Text("✗ " + item.tex).font(.system(size: 11, design: .monospaced)).foregroundStyle(.red)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(12).frame(width: 640).background(Color.white))
            corpus.scale = 2
            if let cg = corpus.cgImage, let data = pngData(cg) { try data.write(to: out.appendingPathComponent("engine-\(slug)-corpus.png")) }

            if scroll {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 800),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "Renderer spike: \(engine.name)"
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                let fresh = InlineMath(engine: engine)
                window.contentView = NSHostingView(rootView:
                    ScrollView { LazyVStack(spacing: 0) { ForEach(Array(rows.enumerated()), id: \.offset) { EngineRow(math: fresh, prose: $0.element, salt: $0.offset) } } }
                        .background(Color.white))
                await sleep(ms: 800)
                r.scroll = await ScrollBench.scrollNative(window: window, down: true)
                window.close()
            }
            r.afterAllMB = footprintMB() - before
            print(r.line)
            if let s = r.scroll { print("  scroll (cold cache): \(s.line)") }
            results.append(r)
        }
        return results
    }
}

/// The typographic fast path in front of an engine.
enum HybridBench {
    struct Result: Codable {
        var engine = ""
        var fastFormulas = 0
        var engineFormulas = 0
        var failedFormulas = 0
        var fastAllMs = 0.0
        var scroll: FrameStats?
    }

    static func run(engines: [(String, () throws -> MathEngine)], macros: MacroSet, out: URL, scroll: Bool) async throws -> [Result] {
        var results: [Result] = []
        let rows = Corpus.rows(200)
        let formulas = rows.flatMap { Corpus.segments($0).compactMap { if case .math(let t) = $0 { t } else { nil } } }
        for (_, make) in engines {
            let engine = try make()
            var r = Result()
            r.engine = engine.name
            let t = now()
            for f in formulas {
                if TypographicMath.text(macros.expand(f)) != nil { r.fastFormulas += 1 }
                else if case .success = engine.layout(f, display: false) { r.engineFormulas += 1 }
                else { r.failedFormulas += 1 }
            }
            r.fastAllMs = now() - t
            let hybrid = HybridMath(engine: engine, macros: macros)
            let sheet = ImageRenderer(content:
                VStack(spacing: 0) { ForEach(Array(Corpus.prose.enumerated()), id: \.offset) { HybridRow(math: hybrid, prose: $0.element) } }
                    .frame(width: 640).background(Color.white))
            sheet.scale = 2
            if let cg = sheet.cgImage, let data = pngData(cg) {
                try data.write(to: out.appendingPathComponent("hybrid-\(EngineBench.slug(engine.name))-prose.png"))
            }
            if scroll {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 800),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "Renderer spike: fast path + \(engine.name)"
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                let fresh = HybridMath(engine: engine, macros: macros)
                window.contentView = NSHostingView(rootView:
                    ScrollView { LazyVStack(spacing: 0) { ForEach(Array(rows.enumerated()), id: \.offset) { HybridRow(math: fresh, prose: $0.element, salt: $0.offset) } } }
                        .background(Color.white))
                await sleep(ms: 800)
                r.scroll = await ScrollBench.scrollNative(window: window, down: true)
                window.close()
            }
            print(String(format: "Fast path + %@: %d fast, %d engine, %d failed of %d; classify+layout all %.1f ms",
                         r.engine, r.fastFormulas, r.engineFormulas, r.failedFormulas, formulas.count, r.fastAllMs))
            if let s = r.scroll { print("  scroll (cold cache): \(s.line)") }
            results.append(r)
        }
        return results
    }
}

/// One sheet with the same four proof steps set by each candidate.
enum CompareSheet {
    static func run(macros: MacroSet, out: URL) async throws {
        let picks = [0, 3, 6, 7].map { Corpus.prose[$0] }
        let microtex = try MicroTeXEngine(fontFile: "XITSMath-Regular", macros: macros)
        let mathjax = try MathJaxEngine(macros: macros)
        let rasterizer = KaTeXRasterizer(macros: macros, folder: try KaTeXPage.makeFolder())
        try await rasterizer.rasterize(picks.flatMap { Corpus.segments($0).compactMap { if case .math(let t) = $0 { t } else { nil } } })
        let swiftmath = SwiftMathEngine(macros: macros, compat: true)

        struct Block: View {
            let title: String
            let detail: String
            let rows: [AnyView]
            var body: some View {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
                    ForEach(rows.indices, id: \.self) { rows[$0] }
                }
            }
        }
        let sm = InlineMath(engine: swiftmath), mt = InlineMath(engine: microtex), mj = InlineMath(engine: mathjax)
        let hmt = HybridMath(engine: microtex, macros: macros), hmj = HybridMath(engine: mathjax, macros: macros)
        let sheet = ImageRenderer(content:
            VStack(alignment: .leading, spacing: 0) {
                Block(title: "A · SwiftMath + compatibility", detail: "native · red = unsupported",
                      rows: picks.map { AnyView(EngineRow(math: sm, prose: $0)) })
                Block(title: "B · KaTeX images", detail: "hidden WKWebView, +75 MB, ~0.5 s per batch",
                      rows: picks.map { AnyView(RasterRow(rasterizer: rasterizer, prose: $0)) })
                Block(title: "C · MicroTeX (XITS Math)", detail: "native C++, 22 µs per formula, +13 MB",
                      rows: picks.map { AnyView(EngineRow(math: mt, prose: $0)) })
                Block(title: "D · MathJax 4 (STIX Two)", detail: "JavaScriptCore, ~1 ms per formula, +36 MB",
                      rows: picks.map { AnyView(EngineRow(math: mj, prose: $0)) })
                Block(title: "E · Text fast path + MicroTeX", detail: "86% of formulas as selectable text",
                      rows: picks.map { AnyView(HybridRow(math: hmt, prose: $0)) })
                Block(title: "F · Text fast path + MathJax", detail: "86% as text, MathJax for the rest",
                      rows: picks.map { AnyView(HybridRow(math: hmj, prose: $0)) })
            }
            .frame(width: 660).background(Color.white))
        sheet.scale = 2
        if let cg = sheet.cgImage, let data = pngData(cg) { try data.write(to: out.appendingPathComponent("comparison.png")) }
        print("Wrote comparison.png")
    }
}
