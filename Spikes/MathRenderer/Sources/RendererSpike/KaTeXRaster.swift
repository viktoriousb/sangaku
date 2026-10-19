import AppKit
import SwiftUI
import WebKit

/// Option (c): KaTeX as a batch rasterizer. One hidden WKWebView typesets many formulas per page,
/// reports each one's box and baseline, takes one snapshot, and crops it. The crops sit inline in
/// SwiftUI `Text` exactly like SwiftMath's images, so rows stay native.
final class KaTeXRasterizer: NSObject, WKScriptMessageHandler {
    struct Box: Sendable {
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0, descent = 0.0, ok = true
    }

    private let webView: WKWebView
    private let window: NSWindow
    private let folder: URL
    private let macros: MacroSet
    private let fontSize: CGFloat
    private var continuation: CheckedContinuation<[Box], Never>?
    private(set) var cache: [String: SwiftMathRenderer.Rendered] = [:]
    private(set) var snapshotScale: CGFloat = 1

    init(macros: MacroSet, folder: URL, fontSize: CGFloat = 16) {
        self.macros = macros
        self.folder = folder
        self.fontSize = fontSize
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        window = offscreenWindow(size: NSSize(width: 1200, height: 800))
        super.init()
        configuration.userContentController.add(self, name: "boxes")
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView = webView
    }

    /// Rasterizes every formula not yet cached, `batch` formulas per page and snapshot.
    func rasterize(_ formulas: [String], batch: Int = 150) async throws {
        let todo = Array(Set(formulas.filter { cache[$0] == nil }))
        var start = 0
        while start < todo.count {
            let chunk = Array(todo[start..<min(start + batch, todo.count)])
            try await rasterizeBatch(chunk)
            start += batch
        }
    }

    func rendered(_ tex: String) -> SwiftMathRenderer.Rendered? { cache[tex] }

    private func rasterizeBatch(_ formulas: [String]) async throws {
        let formulasJSON = String(data: try JSONSerialization.data(withJSONObject: formulas), encoding: .utf8)!
        let macrosJSON = String(data: try JSONSerialization.data(withJSONObject: macros.katexMacros), encoding: .utf8)!
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <link rel="stylesheet" href="katex/katex.min.css">
        <style>
          html, body { margin: 0; background: transparent; color: #000; }
          body { font-size: \(Int(fontSize))px; }
          .cell { display: block; padding: 6px 4px; white-space: nowrap; }
          .f { display: inline-block; }
          .b { display: inline-block; width: 0; height: 0; vertical-align: baseline; }
          .katex { font-size: 1.1em; }  /* KaTeX's default 1.21em suits Times; STIX Two has a larger x-height */
        </style>
        <script src="katex/katex.min.js"></script></head><body><div id="root"></div>
        <script>
          const formulas = \(formulasJSON);
          const macros = \(macrosJSON);
          const root = document.getElementById('root');
          root.innerHTML = formulas.map((f, i) => {
            let html, ok = true;
            try { html = katex.renderToString(f, { throwOnError: true, strict: "ignore", macros: Object.assign({}, macros) }); }
            catch (e) { ok = false; html = '<span style="color:#B91C1C">' + f.replace(/[&<>]/g, '') + '</span>'; }
            return '<div class="cell"><span class="f" data-ok="' + ok + '"><span class="b"></span>' + html + '</span></div>';
          }).join('');
          function measure() {
            const boxes = Array.from(document.querySelectorAll('.f')).map(el => {
              const r = el.getBoundingClientRect();
              const k = el.querySelector('.katex') || el;
              const kr = k.getBoundingClientRect();
              const top = Math.min(r.top, kr.top), bottom = Math.max(r.bottom, kr.bottom);
              const left = Math.min(r.left, kr.left), right = Math.max(r.right, kr.right);
              const baseline = el.querySelector('.b').getBoundingClientRect().top;
              return { x: left, y: top + window.scrollY, width: right - left, height: bottom - top,
                       descent: bottom - baseline, ok: el.dataset.ok === 'true' };
            });
            window.webkit.messageHandlers.boxes.postMessage({ boxes: boxes, height: document.documentElement.scrollHeight });
          }
          document.fonts.ready.then(() => setTimeout(measure, 30));
        </script></body></html>
        """
        let page = folder.appendingPathComponent("raster-\(UUID().uuidString).html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        let boxes: [Box] = await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadFileURL(page, allowingReadAccessTo: folder)
        }
        guard !boxes.isEmpty else { return }
        let height = (boxes.map { $0.y + $0.height }.max() ?? 800) + 10
        window.setContentSize(NSSize(width: 1200, height: height))
        webView.frame = NSRect(x: 0, y: 0, width: 1200, height: height)
        await sleep(ms: 30)
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: 1200, height: height)
        let snapshot = try await webView.takeSnapshot(configuration: config)
        guard let cg = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scale = CGFloat(cg.width) / 1200
        snapshotScale = scale
        for (tex, box) in zip(boxes.isEmpty ? [] : formulas, boxes) where box.ok {
            let rect = CGRect(x: floor(box.x * scale), y: floor(box.y * scale),
                              width: ceil(box.width * scale) + 1, height: ceil(box.height * scale) + 1)
            guard let crop = cg.cropping(to: rect), let (ink, top, bottom) = Self.trimToInk(crop) else { continue }
            _ = top
            let image = NSImage(cgImage: ink, size: NSSize(width: CGFloat(ink.width) / scale, height: CGFloat(ink.height) / scale))
            image.isTemplate = true
            // Baseline position in snapshot pixels (top-down); the descent is the ink left below it.
            let baselineY = (box.y + box.height - box.descent) * scale
            let descent = (rect.maxY - CGFloat(bottom) - baselineY) / scale
            cache[tex] = SwiftMathRenderer.Rendered(image: image, descent: descent)
        }
    }

    /// Crops transparent rows from the top and bottom. Returns the image and the rows removed at each end.
    static func trimToInk(_ image: CGImage) -> (CGImage, Int, Int)? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The context's memory starts at the image's top row.
        func rowHasInk(_ y: Int) -> Bool {
            var x = 0
            while x < w { if pixels[(y * w + x) * 4 + 3] > 8 { return true }; x += 1 }
            return false
        }
        var top = 0
        while top < h, !rowHasInk(top) { top += 1 }
        guard top < h else { return nil }
        var bottom = h - 1
        while bottom > top, !rowHasInk(bottom) { bottom -= 1 }
        guard let cropped = image.cropping(to: CGRect(x: 0, y: top, width: w, height: bottom - top + 1)) else { return nil }
        return (cropped, top, h - 1 - bottom)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        let raw = body["boxes"] as? [[String: Any]] ?? []
        let boxes = raw.map { d in
            Box(x: d["x"] as? Double ?? 0, y: d["y"] as? Double ?? 0,
                width: d["width"] as? Double ?? 0, height: d["height"] as? Double ?? 0,
                descent: d["descent"] as? Double ?? 0, ok: d["ok"] as? Bool ?? false)
        }
        continuation?.resume(returning: boxes)
        continuation = nil
    }

    /// A paragraph built from cached rasters; uncached formulas show their source in red.
    func paragraph(_ prose: String) -> Text {
        var text = Text("")
        let joiner = "\u{2060}"
        for segment in Corpus.segments(prose) {
            switch segment {
            case .text(var s):
                if let first = s.first, !first.isWhitespace { s = joiner + s }
                if let last = s.last, !last.isWhitespace { s += joiner }
                text = text + Text(s)
            case .math(let tex):
                if let r = cache[tex] {
                    text = text + Text(Image(nsImage: r.image).renderingMode(.template)).baselineOffset(-r.descent)
                } else {
                    text = text + Text(tex).foregroundStyle(.red)
                }
            }
        }
        return text
    }
}

struct RasterRow: View {
    let rasterizer: KaTeXRasterizer
    let prose: String

    var body: some View {
        rasterizer.paragraph(prose)
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

enum RasterBench {
    struct Result: Codable {
        var formulas = 0
        var uniqueFormulas = 0
        var rasterizeMs = 0.0
        var snapshotScale = 0.0
        var webContentMB = 0.0
        var scroll: FrameStats?
    }

    static func run(macros: MacroSet, out: URL, scroll: Bool) async throws -> Result {
        var result = Result()
        let rows = Corpus.rows(200)
        let formulas = rows.flatMap { Corpus.segments($0).compactMap { if case .math(let t) = $0 { t } else { nil } } }
        result.formulas = formulas.count
        result.uniqueFormulas = Set(formulas).count
        let folder = try KaTeXPage.makeFolder()
        let baseline = webContentMB()
        let rasterizer = KaTeXRasterizer(macros: macros, folder: folder)

        // Unique formulas only, as a cache keyed by (LaTeX, macros, size) would see. Add the corpus too,
        // so the timing covers more than the eight repeating prose rows.
        let corpus = Corpus.expressions.map(\.tex)
        let t = now()
        try await rasterizer.rasterize(formulas + corpus)
        result.rasterizeMs = now() - t
        result.snapshotScale = rasterizer.snapshotScale
        result.webContentMB = webContentMB() - baseline
        print(String(format: "KaTeX raster: %d formulas (%d unique in prose, %d corpus) in %.1f ms at scale %.0f; WebContent +%.0f MB",
                     formulas.count, result.uniqueFormulas, corpus.count, result.rasterizeMs, result.snapshotScale, result.webContentMB))

        let sheet = ImageRenderer(content:
            VStack(spacing: 0) { ForEach(Array(Corpus.prose.enumerated()), id: \.offset) { RasterRow(rasterizer: rasterizer, prose: $0.element) } }
                .frame(width: 640).background(Color.white))
        sheet.scale = 2
        if let cg = sheet.cgImage, let data = pngData(cg) {
            try data.write(to: out.appendingPathComponent("katex-raster-prose.png"))
        }
        let dark = ImageRenderer(content:
            VStack(spacing: 0) { ForEach(Array(Corpus.prose.prefix(3).enumerated()), id: \.offset) {
                rasterizer.paragraph($0.element).font(.custom("STIX Two Text", size: 16)).foregroundStyle(Color(white: 0.92))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            } }
            .frame(width: 640).background(Color(white: 0.11)))
        dark.scale = 2
        if let cg = dark.cgImage, let data = pngData(cg) {
            try data.write(to: out.appendingPathComponent("katex-raster-dark.png"))
        }

        if scroll {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 800),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Renderer spike: KaTeX rasters in SwiftUI rows"
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            window.contentView = NSHostingView(rootView:
                ScrollView { LazyVStack(spacing: 0) { ForEach(Array(rows.enumerated()), id: \.offset) { RasterRow(rasterizer: rasterizer, prose: $0.element) } } }
                    .background(Color.white))
            await sleep(ms: 800)
            result.scroll = await ScrollBench.scrollNative(window: window, down: true)
            print("KaTeX raster rows: \(result.scroll?.line ?? "-")")
            window.close()
        }
        return result
    }
}
