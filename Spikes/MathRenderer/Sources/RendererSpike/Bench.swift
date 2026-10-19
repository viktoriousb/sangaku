import AppKit
import QuartzCore
import SwiftUI
import WebKit

// MARK: - Helpers

func now() -> Double { CACurrentMediaTime() * 1000 }

func sleep(ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

/// Resident memory of all WebKit content processes, in MB. Compare before and after; other apps' web
/// content processes are included in both readings.
func webContentMB() -> Double {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "rss=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let kb = out.split(separator: "\n").filter { $0.contains("WebContent") }
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }
        .reduce(0, +)
    return kb / 1024
}

/// This process's physical footprint, in MB.
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

struct FrameStats: Codable {
    var frames: Int
    var nominalMs: Double
    var medianMs: Double
    var p95Ms: Double
    var p99Ms: Double
    var maxMs: Double
    /// Frames that took more than 1.5 × the display's frame duration.
    var hitches: Int
    /// Main-thread work per frame (scroll, layout, display), independent of the display's refresh rate.
    var workMedianMs = 0.0
    var workP95Ms = 0.0
    var workP99Ms = 0.0
    var workMaxMs = 0.0

    init(intervals: [Double], nominal: Double, work: [Double] = []) {
        let s = intervals.sorted()
        func q(_ p: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
        frames = s.count
        nominalMs = nominal
        medianMs = q(0.5)
        p95Ms = q(0.95)
        p99Ms = q(0.99)
        maxMs = s.last ?? 0
        hitches = s.filter { $0 > nominal * 1.5 }.count
        let w = work.sorted()
        func wq(_ p: Double) -> Double { w.isEmpty ? 0 : w[min(w.count - 1, Int(Double(w.count) * p))] }
        workMedianMs = wq(0.5)
        workP95Ms = wq(0.95)
        workP99Ms = wq(0.99)
        workMaxMs = w.last ?? 0
    }

    var line: String {
        String(format: "%d frames, nominal %.1f ms, median %.1f, p95 %.1f, p99 %.1f, max %.1f, hitches %d (%.1f%%); work median %.2f, p95 %.2f, p99 %.2f, max %.2f ms",
               frames, nominalMs, medianMs, p95Ms, p99Ms, maxMs, hitches,
               frames == 0 ? 0 : 100 * Double(hitches) / Double(frames),
               workMedianMs, workP95Ms, workP99Ms, workMaxMs)
    }
}

func pngData(_ image: CGImage) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

func offscreenWindow(size: NSSize) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    return window
}

// MARK: - Coverage

enum Coverage {
    struct Row: Codable {
        let category: String
        let tex: String
        let swiftMath: String?
        let swiftMathWithFallbacks: String?
        let katex: String?
    }

    static func run(macros: MacroSet, katex: KaTeXJS, out: URL) throws -> [Row] {
        let swiftMath = SwiftMathRenderer(macros: macros)
        let rows = Corpus.expressions.map { item in
            Row(category: item.category, tex: item.tex,
                swiftMath: swiftMath.parseError(item.tex, fallbacks: false),
                swiftMathWithFallbacks: swiftMath.parseError(item.tex, fallbacks: true),
                katex: katex.parseError(item.tex, display: item.display))
        }
        func cell(_ e: String?) -> String { e == nil ? "✓" : "✗ " + e!.replacingOccurrences(of: "|", with: "\\|") }
        var md = "| Kind | LaTeX | SwiftMath | SwiftMath + fallbacks | KaTeX |\n|---|---|---|---|---|\n"
        for r in rows {
            md += "| \(r.category) | `\(r.tex.replacingOccurrences(of: "|", with: "\\|"))` | \(cell(r.swiftMath)) | \(cell(r.swiftMathWithFallbacks)) | \(cell(r.katex)) |\n"
        }
        let total = rows.count
        let summary = String(format: "Parsed: SwiftMath %d/%d, SwiftMath + fallbacks %d/%d, KaTeX %d/%d\n",
                             rows.filter { $0.swiftMath == nil }.count, total,
                             rows.filter { $0.swiftMathWithFallbacks == nil }.count, total,
                             rows.filter { $0.katex == nil }.count, total)
        try (summary + "\n" + md).write(to: out.appendingPathComponent("coverage.md"), atomically: true, encoding: .utf8)
        print(summary)
        return rows
    }
}

// MARK: - Images

enum Images {
    static func run(macros: MacroSet, out: URL) async throws {
        let renderer = SwiftMathRenderer(macros: macros)

        // SwiftMath: prose rows.
        let prose = ImageRenderer(content:
            VStack(spacing: 0) { ForEach(Array(Corpus.prose.enumerated()), id: \.offset) { SwiftMathRow(renderer: renderer, prose: $0.element) } }
                .frame(width: 640).background(Color.white))
        prose.scale = 2
        if let cg = prose.cgImage, let data = pngData(cg) {
            try data.write(to: out.appendingPathComponent("swiftmath-prose.png"))
        }

        // SwiftMath: every corpus expression.
        let display = ImageRenderer(content:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Corpus.expressions.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .center, spacing: 10) {
                        Text(item.category).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        if let r = renderer.render(item.tex, display: item.display) {
                            Image(nsImage: r.image)
                        } else {
                            Text("✗ " + item.tex).font(.system(size: 11, design: .monospaced)).foregroundStyle(.red)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(12).frame(width: 640).background(Color.white))
        display.scale = 2
        if let cg = display.cgImage, let data = pngData(cg) {
            try data.write(to: out.appendingPathComponent("swiftmath-corpus.png"))
        }

        // KaTeX: the same two sheets, snapshotted from a WKWebView.
        let folder = try KaTeXPage.makeFolder()
        try await snapshot(rows: Corpus.prose, macros: macros, folder: folder, to: out.appendingPathComponent("katex-prose.png"))
        let corpusRows = Corpus.expressions.map { "\($0.category): $\($0.display ? "\\displaystyle " : "")\($0.tex)$" }
        try await snapshot(rows: corpusRows, macros: macros, folder: folder, to: out.appendingPathComponent("katex-corpus.png"))
        print("Wrote swiftmath-prose.png, swiftmath-corpus.png, katex-prose.png, katex-corpus.png")
    }

    static func snapshot(rows: [String], macros: MacroSet, folder: URL, to url: URL) async throws {
        let window = offscreenWindow(size: NSSize(width: 640, height: 400))
        let page = KaTeXPage(frame: NSRect(x: 0, y: 0, width: 640, height: 400), folder: folder)
        window.contentView = page.webView
        let message = try await page.load(rows: rows, macros: macros)
        let height = message.height > 0 ? message.height : 400
        window.setContentSize(NSSize(width: 640, height: height))
        await sleep(ms: 300)
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: 640, height: height)
        let image = try await page.webView.takeSnapshot(configuration: config)
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = pngData(cg) {
            try data.write(to: url)
        }
        window.close()
    }
}

// MARK: - Headless timings

enum Perf {
    struct Result: Codable {
        var formulas = 0
        var swiftMathTypesetMs = 0.0
        var swiftMathDrawMs = 0.0
        var swiftUIAllRowsMs = 0.0
        var katexJSCMs = 0.0
        var singlePageWallMs = 0.0
        var singlePageInPageMs = 0.0
        var singlePageWebContentMB = 0.0
        var perRowViews = 0
        var perRowWallMs = 0.0
        var perRowMedianLatencyMs = 0.0
        var perRowMaxLatencyMs = 0.0
        var perRowWebContentMB = 0.0
        var footprintMB = 0.0
    }

    static func run(macros: MacroSet, katex: KaTeXJS, out: URL) async throws -> Result {
        var r = Result()
        let rows = Corpus.rows(200)
        let formulas = rows.flatMap { Corpus.segments($0).compactMap { if case .math(let t) = $0 { t } else { nil } } }
        r.formulas = formulas.count

        // SwiftMath, no cache: typeset, then force drawing into a bitmap.
        let renderer = SwiftMathRenderer(macros: macros)
        renderer.useCache = false
        var t = now()
        let images = formulas.compactMap { renderer.render($0)?.image }
        r.swiftMathTypesetMs = now() - t
        let ctx = CGContext(data: nil, width: 800, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        t = now()
        for image in images { image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1) }
        r.swiftMathDrawMs = now() - t
        NSGraphicsContext.current = nil

        // SwiftUI lays out and draws all 200 rows at once (an upper bound on any scroll position).
        let cached = SwiftMathRenderer(macros: macros)
        t = now()
        let all = ImageRenderer(content:
            VStack(spacing: 0) { ForEach(Array(rows.enumerated()), id: \.offset) { SwiftMathRow(renderer: cached, prose: $0.element) } }
                .frame(width: 640))
        _ = all.cgImage
        r.swiftUIAllRowsMs = now() - t

        // KaTeX in JavaScriptCore.
        t = now()
        for f in formulas { _ = katex.renderToString(f, display: false) }
        r.katexJSCMs = now() - t

        // KaTeX: one WKWebView holding all 200 rows.
        let folder = try KaTeXPage.makeFolder()
        let baseline = webContentMB()
        let window = offscreenWindow(size: NSSize(width: 640, height: 800))
        let page = KaTeXPage(frame: NSRect(x: 0, y: 0, width: 640, height: 800), folder: folder)
        window.contentView = page.webView
        t = now()
        let message = try await page.load(rows: rows, macros: macros)
        r.singlePageWallMs = now() - t
        r.singlePageInPageMs = message.totalMs
        await sleep(ms: 500)
        r.singlePageWebContentMB = webContentMB() - baseline
        window.close()
        await sleep(ms: 1500)

        // KaTeX: one WKWebView per row, as a lazy list would create them.
        let perRow = 40
        r.perRowViews = perRow
        let baseline2 = webContentMB()
        let window2 = offscreenWindow(size: NSSize(width: 640, height: CGFloat(perRow) * 84))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: CGFloat(perRow) * 84))
        window2.contentView = container
        let box = LatencyBox()
        var pages: [KaTeXPage] = []
        t = now()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            box.remaining = perRow
            box.done = { done.resume() }
            for i in 0..<perRow {
                let p = KaTeXPage(frame: NSRect(x: 0, y: CGFloat(i) * 84, width: 640, height: 84), folder: folder)
                container.addSubview(p.webView)
                pages.append(p)
                let start = now()
                Task {
                    _ = try? await p.load(rows: [rows[i]], macros: macros)
                    box.add(now() - start)
                }
            }
        }
        r.perRowWallMs = now() - t
        let latencies = box.latencies.sorted()
        r.perRowMedianLatencyMs = latencies[latencies.count / 2]
        r.perRowMaxLatencyMs = latencies.last ?? 0
        await sleep(ms: 500)
        r.perRowWebContentMB = webContentMB() - baseline2
        window2.close()
        pages.removeAll()
        r.footprintMB = footprintMB()

        print(String(format: """
        Formulas in 200 rows: %d
        SwiftMath typeset (no cache): %.1f ms, draw: %.1f ms
        SwiftUI, all 200 rows laid out and drawn: %.1f ms
        KaTeX renderToString in JavaScriptCore: %.1f ms
        KaTeX single page: %.1f ms wall (%.1f ms in page), WebContent +%.0f MB
        KaTeX per-row: %d web views in %.1f ms; latency median %.1f ms, max %.1f ms; WebContent +%.0f MB
        """, r.formulas, r.swiftMathTypesetMs, r.swiftMathDrawMs, r.swiftUIAllRowsMs, r.katexJSCMs,
              r.singlePageWallMs, r.singlePageInPageMs, r.singlePageWebContentMB,
              r.perRowViews, r.perRowWallMs, r.perRowMedianLatencyMs, r.perRowMaxLatencyMs, r.perRowWebContentMB))
        return r
    }
}

// MARK: - Live scrolling

/// Collects load latencies from tasks on the main actor.
final class LatencyBox {
    var latencies: [Double] = []
    var remaining = 0
    var done: (() -> Void)?

    func add(_ latency: Double) {
        latencies.append(latency)
        remaining -= 1
        if remaining == 0 { done?(); done = nil }
    }
}

final class Ticker: NSObject {
    var onTick: (CADisplayLink) -> Bool = { _ in false }
    @objc func tick(_ link: CADisplayLink) {
        if !onTick(link) { link.invalidate() }
    }
}

/// A per-row WKWebView, the configuration the spec says never to ship without measuring.
struct WebRow: NSViewRepresentable {
    let prose: String
    let macros: MacroSet
    let folder: URL
    let onLoaded: (Double) -> Void

    final class Coordinator { var page: KaTeXPage? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let page = KaTeXPage(frame: NSRect(x: 0, y: 0, width: 640, height: 84), folder: folder)
        context.coordinator.page = page
        let start = now()
        Task {
            _ = try? await page.load(rows: [prose], macros: macros)
            onLoaded(now() - start)
        }
        return page.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

enum ScrollBench {
    struct Result: Codable {
        var swiftMathCold: FrameStats?
        var swiftMathWarm: FrameStats?
        var webRows: FrameStats?
        var webRowsCreated = 0
        var webRowsMedianLatencyMs = 0.0
        var webRowsMaxLatencyMs = 0.0
        var singlePage: FrameStats?
    }

    static let speed = 2500.0 // points per second, a brisk flick

    static func run(macros: MacroSet, out: URL) async throws -> Result {
        var result = Result()
        let rows = Corpus.rows(200)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 800),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Renderer spike: scrolling 200 rows"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // (a) SwiftMath rows in a lazy stack.
        let renderer = SwiftMathRenderer(macros: macros)
        window.contentView = NSHostingView(rootView:
            ScrollView { LazyVStack(spacing: 0) { ForEach(Array(rows.enumerated()), id: \.offset) { SwiftMathRow(renderer: renderer, prose: $0.element) } } }
                .background(Color.white))
        await sleep(ms: 800)
        result.swiftMathCold = await scrollNative(window: window, down: true)
        result.swiftMathWarm = await scrollNative(window: window, down: false)
        print("SwiftMath cold: \(result.swiftMathCold?.line ?? "-")")
        print("SwiftMath warm: \(result.swiftMathWarm?.line ?? "-")")

        // (c) One WKWebView holding every row, scrolled in-page; frames measured with requestAnimationFrame.
        let folder = try KaTeXPage.makeFolder()
        let page = KaTeXPage(frame: NSRect(x: 0, y: 0, width: 680, height: 800), folder: folder)
        window.contentView = page.webView
        let bench = """
        window.__bench = function(speed) {
          const deltas = []; let last = null; let y = 0;
          const max = document.documentElement.scrollHeight - window.innerHeight;
          function step(t) {
            if (last !== null) { deltas.push(t - last); y += speed * (t - last) / 1000; }
            last = t; window.scrollTo(0, y);
            if (y < max && deltas.length < 2000) requestAnimationFrame(step);
            else window.webkit.messageHandlers.done.postMessage({ deltas: deltas });
          }
          requestAnimationFrame(step);
        };
        """
        _ = try await page.load(rows: rows, macros: macros, extraScript: bench)
        await sleep(ms: 500)
        async let message = page.nextMessage()
        _ = try? await page.webView.evaluateJavaScript("__bench(\(speed)); 0")
        let deltas = (await message).deltas
        let sorted = deltas.sorted()
        let nominal = sorted.isEmpty ? 16.7 : sorted[sorted.count / 2]
        result.singlePage = FrameStats(intervals: deltas, nominal: nominal)
        print("Single page: \(result.singlePage?.line ?? "-")")
        // (b) One WKWebView per row in a lazy stack.
        let box = LatencyBox()
        window.contentView = NSHostingView(rootView:
            ScrollView { LazyVStack(spacing: 0) { ForEach(Array(rows.enumerated()), id: \.offset) { item in
                WebRow(prose: item.element, macros: macros, folder: folder) { box.add($0) }.frame(height: 84)
            } } }
            .background(Color.white))
        await sleep(ms: 1500)
        result.webRows = await scrollNative(window: window, down: true)
        await sleep(ms: 1500)
        let latencies = box.latencies.sorted()
        result.webRowsCreated = latencies.count
        result.webRowsMedianLatencyMs = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
        result.webRowsMaxLatencyMs = latencies.last ?? 0
        print("Web rows: \(result.webRows?.line ?? "-")")
        print(String(format: "Web rows created: %d, load latency median %.1f ms, max %.1f ms",
                     result.webRowsCreated, result.webRowsMedianLatencyMs, result.webRowsMaxLatencyMs))

        window.close()
        return result
    }

    /// Scrolls the hosting view's NSScrollView at `speed`, one step per display frame, and records frame intervals.
    static func scrollNative(window: NSWindow, down: Bool) async -> FrameStats? {
        guard let content = window.contentView, let scrollView = findScrollView(content) else {
            print("No NSScrollView found"); return nil
        }
        let ticker = Ticker()
        var intervals: [Double] = []
        var work: [Double] = []
        var nominal = 16.7
        var last: CFTimeInterval?
        let start = now()
        return await withCheckedContinuation { continuation in
            ticker.onTick = { link in
                let workStart = now()
                let ts = link.timestamp
                nominal = (link.targetTimestamp - link.timestamp) * 1000
                let dt = last.map { ts - $0 } ?? (1.0 / 60)
                if last != nil { intervals.append(dt * 1000) }
                last = ts
                let clip = scrollView.contentView
                let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
                var y = clip.bounds.origin.y + (down ? 1 : -1) * speed * dt
                y = min(max(0, y), maxY)
                clip.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(clip)
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                work.append(now() - workStart)
                let finished = (down ? y >= maxY - 0.5 : y <= 0.5) || now() - start > 15000
                if finished {
                    continuation.resume(returning: FrameStats(intervals: intervals, nominal: nominal, work: work))
                    return false
                }
                return true
            }
            let link = content.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
            link.add(to: .main, forMode: .common)
        }
    }

    static func findScrollView(_ view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews { if let s = findScrollView(sub) { return s } }
        return nil
    }
}
