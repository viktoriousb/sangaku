import AppKit
import JavaScriptCore
import WebKit

enum SpikeError: Error {
    case missingResource(String)
    case javascript(String)
    case timeout(String)
}

/// Option (b), coverage half: KaTeX in JavaScriptCore, no web view. Used to test parsing and to time
/// `renderToString`.
final class KaTeXJS {
    private let context: JSContext
    private let renderFunction: JSValue
    private let macros: [String: String]

    init(macros: MacroSet) throws {
        guard let url = Bundle.module.url(forResource: "katex.min", withExtension: "js", subdirectory: "katex"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw SpikeError.missingResource("katex.min.js")
        }
        guard let context = JSContext() else { throw SpikeError.javascript("no JSContext") }
        self.context = context
        context.evaluateScript("var self = this;")
        context.evaluateScript(source)
        context.evaluateScript("""
        function __render(tex, display, macros) {
          try {
            return { ok: true, html: katex.renderToString(tex, {
              displayMode: display, throwOnError: true, strict: "ignore", macros: Object.assign({}, macros) }) };
          } catch (e) { return { ok: false, err: String((e && e.message) || e) }; }
        }
        """)
        guard let fn = context.objectForKeyedSubscript("__render"), !fn.isUndefined,
              context.objectForKeyedSubscript("katex")?.isUndefined == false else {
            throw SpikeError.javascript("katex did not load: \(context.exception?.toString() ?? "?")")
        }
        renderFunction = fn
        self.macros = macros.katexMacros
    }

    /// Returns nil on success, or KaTeX's error message.
    func parseError(_ tex: String, display: Bool) -> String? {
        let result = renderFunction.call(withArguments: [tex, display, macros])
        if result?.objectForKeyedSubscript("ok")?.toBool() == true { return nil }
        return result?.objectForKeyedSubscript("err")?.toString() ?? "unknown error"
    }

    func renderToString(_ tex: String, display: Bool) -> String? {
        let result = renderFunction.call(withArguments: [tex, display, macros])
        return result?.objectForKeyedSubscript("html")?.toString()
    }
}

/// What the page posts back through `done`.
struct PageMessage: Sendable {
    var renderMs = 0.0
    var totalMs = 0.0
    var height = 0.0
    var deltas: [Double] = []

    init(_ body: Any) {
        let d = body as? [String: Any] ?? [:]
        renderMs = d["renderMs"] as? Double ?? 0
        totalMs = d["totalMs"] as? Double ?? 0
        height = d["height"] as? Double ?? 0
        deltas = d["deltas"] as? [Double] ?? []
        if let error = d["error"] as? String { print("page error: \(error)") }
    }
}

/// Option (b), display half: KaTeX in a WKWebView. Builds a page in a temporary folder next to a
/// copy of KaTeX's files and reports back through a script message.
final class KaTeXPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private var continuation: CheckedContinuation<PageMessage, Never>?
    
    private let folder: URL

    static let katexFolder: URL? = Bundle.module.url(forResource: "katex", withExtension: nil)

    init(frame: NSRect, folder: URL) {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: frame, configuration: configuration)
        self.folder = folder
        super.init()
        configuration.userContentController.add(self, name: "done")
        webView.navigationDelegate = self
    }

    static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-spike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let katex = katexFolder else { throw SpikeError.missingResource("katex folder") }
        try FileManager.default.copyItem(at: katex, to: folder.appendingPathComponent("katex"))
        return folder
    }

    /// Loads one page with every row and waits until KaTeX has rendered and the layout settled.
    func load(rows: [String], macros: MacroSet, extraScript: String = "") async throws -> PageMessage {
        let rowsJSON = String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!
        let macrosJSON = String(data: try JSONSerialization.data(withJSONObject: macros.katexMacros), encoding: .utf8)!
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <link rel="stylesheet" href="katex/katex.min.css">
        <style>
          html, body { margin: 0; background: #fff; }
          body { font-family: 'STIX Two Text', serif; font-size: 16px; line-height: 1.45; color: #16181D; }
          .row { padding: 8px 14px; border-bottom: 1px solid #ebebeb; }
          .err { color: #B91C1C; }
          .katex { font-size: 1.0em; }
        </style>
        <script src="katex/katex.min.js"></script></head><body><div id="root"></div>
        <script>
          const t0 = performance.now();
          const rows = \(rowsJSON);
          const macros = \(macrosJSON);
          function esc(s) { return s.replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'})[c]); }
          function renderProse(s) {
            return s.split(/(?<!\\\\)\\$/).map((part, i) => {
              if (i % 2 === 0) return esc(part);
              try { return katex.renderToString(part, { throwOnError: true, strict: "ignore", macros: Object.assign({}, macros) }); }
              catch (e) { return '<span class="err">' + esc(part) + '</span>'; }
            }).join('');
          }
          const root = document.getElementById('root');
          const html = rows.map(r => '<div class="row">' + renderProse(r) + '</div>').join('');
          root.innerHTML = html;
          const tRender = performance.now() - t0;
          function report() {
            window.webkit.messageHandlers.done.postMessage({
              renderMs: tRender, totalMs: performance.now() - t0, height: document.documentElement.scrollHeight });
          }
          // requestAnimationFrame does not fire in a hidden (offscreen) page, so fall back to a timer there.
          const settle = document.hidden ? (f => setTimeout(f, 50)) : (f => requestAnimationFrame(() => requestAnimationFrame(f)));
          document.fonts.ready.then(() => settle(report));
          window.onerror = (m) => window.webkit.messageHandlers.done.postMessage({ error: String(m) });
          \(extraScript)
        </script></body></html>
        """
        let page = folder.appendingPathComponent("page-\(UUID().uuidString).html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadFileURL(page, allowingReadAccessTo: folder)
            Task { [weak self] in
                await sleep(ms: 20_000)
                if let pending = self?.continuation {
                    print("KaTeX page timed out")
                    self?.continuation = nil
                    pending.resume(returning: PageMessage([:]))
                }
            }
        }
    }

    /// Waits for the next message posted to `done` (used by in-page benchmarks).
    func nextMessage() async -> PageMessage {
        await withCheckedContinuation { continuation in self.continuation = continuation }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("provisional navigation failed: \(error)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("web content process terminated")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        continuation?.resume(returning: PageMessage(message.body))
        continuation = nil
    }
}
