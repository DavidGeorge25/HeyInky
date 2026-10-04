import CryptoKit
import Foundation
import WebKit

/// Renders Inky's SVG diagrams (`insertDiagram`): sanitizes the model's SVG, applies Inky's style
/// kit, fits the view box to the real content, checks the result (overlapping labels, text too
/// small, empty figure) and produces a vector PDF that the Inky layer draws natively.
@MainActor
final class DiagramEngine: NSObject, WKNavigationDelegate {
    static let shared = DiagramEngine()

    /// What the checker found, and the cleaned-up SVG.
    struct Report: Codable, Equatable, Sendable {
        var ok: Bool
        var problems: [String]
        /// Natural size in points (1 SVG unit = 1 point).
        var width: Double
        var height: Double
        var minFontSize: Double
        var textCount: Int
        var svg: String
    }

    enum EngineError: LocalizedError {
        case load(String), script(String), pdf(String)
        var errorDescription: String? {
            switch self {
            case .load(let m): "The diagram renderer didn't start: \(m)"
            case .script(let m): "The diagram couldn't be checked: \(m)"
            case .pdf(let m): "The diagram couldn't be drawn: \(m)"
            }
        }
    }

    /// Text drawn smaller than this on the page reads badly.
    static let minReadablePoints: Double = 8.5

    private var webView: WKWebView?
    private var loaded = false
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var pdfWaiters: [ObjectIdentifier: CheckedContinuation<Void, any Error>] = [:]

    // MARK: Checking

    func prepare(svg: String) async throws -> Report {
        let view = try await checkerView()
        let result = try await view.callAsyncJavaScript("return window.inkyDiagram.prepare(svg);", arguments: ["svg": svg], in: nil, contentWorld: .page)
        guard let text = result as? String, let data = text.data(using: .utf8) else { throw EngineError.script("no result") }
        return try JSONDecoder().decode(Report.self, from: data)
    }

    /// Display size for a report on a page: natural size, shrunk to fit, never so small that
    /// text drops below `minReadablePoints` (unless it must, to fit the page at all).
    static func displaySize(for report: Report, pageSize: CGSize) -> CGSize {
        let w = max(report.width, 1), h = max(report.height, 1)
        let fit = min(1.4, Double(pageSize.width) * 0.9 / w, Double(pageSize.height) * 0.6 / h)
        return CGSize(width: w * fit, height: h * fit)
    }

    /// Problems a figure would have at its display size on this page.
    static func displayProblems(for report: Report, pageSize: CGSize) -> [String] {
        var problems = report.problems
        let size = displaySize(for: report, pageSize: pageSize)
        let scale = Double(size.width) / max(report.width, 1)
        if report.textCount > 0, report.minFontSize * scale < minReadablePoints {
            problems.append(String(format: "text would be only %.0f pt on the page: make the viewBox smaller (about 300–600 wide) or the font-size larger", report.minFontSize * scale))
        }
        return problems
    }

    // MARK: PDF

    /// Cached vector PDF for a prepared SVG.
    func pdf(for report: Report) async throws -> Data {
        let url = Self.cacheURL(for: report.svg)
        if let data = try? Data(contentsOf: url) { return data }
        let size = CGSize(width: max(report.width, 1), height: max(report.height, 1))
        let view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: WKWebViewConfiguration())
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = self
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=\(Int(size.width))">
        <style>html,body{margin:0;padding:0;background:transparent;}svg{display:block;}</style></head>
        <body>\(report.svg)</body></html>
        """
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            pdfWaiters[ObjectIdentifier(view)] = c
            view.loadHTMLString(html, baseURL: nil)
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        let data: Data
        do {
            data = try await view.pdf(configuration: configuration)
        } catch {
            throw EngineError.pdf(error.localizedDescription)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return data
    }

    static func cacheURL(for svg: String) -> URL {
        let digest = SHA256.hash(data: Data(svg.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.cachesDirectory.appendingPathComponent("InkyDiagrams/\(digest).pdf")
    }

    // MARK: Web view plumbing

    private func checkerView() async throws -> WKWebView {
        if let webView, loaded { return webView }
        if webView == nil {
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1200), configuration: WKWebViewConfiguration())
            view.navigationDelegate = self
            #if DEBUG
            view.isInspectable = true
            #endif
            webView = view
            view.loadHTMLString(Self.checkerHTML, baseURL: nil)
        }
        try await withCheckedThrowingContinuation { waiters.append($0) }
        return webView!
    }

    private func finish(_ webView: WKWebView, _ result: Result<Void, any Error>) {
        if let waiter = pdfWaiters.removeValue(forKey: ObjectIdentifier(webView)) {
            waiter.resume(with: result)
            return
        }
        guard webView === self.webView else { return }
        loaded = (try? result.get()) != nil
        if !loaded { self.webView = nil }
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(with: result) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(webView, .success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(webView, .failure(EngineError.load(error.localizedDescription))) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(webView, .failure(EngineError.load(error.localizedDescription))) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { self.webView = nil; loaded = false }
    }

    // MARK: Style kit

    /// Documented for the model in the system prompt ("Diagrams").
    static let kitCSS = """
    .inky{font-family:-apple-system,'SF Pro Rounded','Helvetica Neue',sans-serif;}
    .inky .ink{stroke:#26262E}.inky text.ink{fill:#26262E;stroke:none}
    .inky .accent{stroke:#5B5BD6}.inky text.accent{fill:#5B5BD6;stroke:none}
    .inky .red{stroke:#E0474C}.inky text.red{fill:#E0474C;stroke:none}
    .inky .blue{stroke:#2E6EDE}.inky text.blue{fill:#2E6EDE;stroke:none}
    .inky .green{stroke:#2F9E66}.inky text.green{fill:#2F9E66;stroke:none}
    .inky .orange{stroke:#F2731A}.inky text.orange{fill:#F2731A;stroke:none}
    .inky .gray{stroke:#8A8A94}.inky text.gray{fill:#8A8A94;stroke:none}
    .inky .fill-accent{fill:rgba(91,91,214,0.14)}.inky .fill-red{fill:rgba(224,71,76,0.14)}
    .inky .fill-blue{fill:rgba(46,110,222,0.14)}.inky .fill-green{fill:rgba(47,158,102,0.15)}
    .inky .fill-orange{fill:rgba(242,115,26,0.16)}.inky .fill-yellow{fill:rgba(255,206,40,0.35)}
    .inky .fill-pink{fill:rgba(240,110,170,0.18)}.inky .fill-gray{fill:#F1F1F4}.inky .fill-white{fill:#FFFFFF}
    .inky .fill-ink{fill:#26262E}.inky .fill-none{fill:none}
    .inky .thin{stroke-width:1.2}.inky .thick{stroke-width:3.2}
    .inky .dashed{stroke-dasharray:6 5}.inky .dotted{stroke-dasharray:1.5 4}
    .inky text.title{font-size:18px;font-weight:600}.inky text.label{font-size:14px}
    .inky text.small{font-size:12px}.inky text.big{font-size:16px}.inky text.bold{font-weight:600}
    .inky text.italic{font-style:italic}.inky text.hand{font-family:'Noteworthy',cursive}
    .inky text.center{text-anchor:middle}.inky text.end{text-anchor:end}
    """

    static let checkerHTML = """
    <!doctype html><html><head><meta charset="utf-8"><style>body{margin:0}#host svg{position:absolute;left:0;top:0;}</style></head>
    <body><div id="host"></div><script>
    const KIT = \(jsonString(kitCSS));
    const SVGNS = 'http://www.w3.org/2000/svg';
    const ALLOWED = new Set(['svg','g','defs','marker','path','line','polyline','polygon','rect','circle','ellipse','text','tspan','title','desc','use','lineargradient','radialgradient','stop','clippath','symbol','style']);
    const COLORS = {ink:'#26262E',accent:'#5B5BD6',red:'#E0474C',blue:'#2E6EDE',green:'#2F9E66',orange:'#F2731A',gray:'#8A8A94'};
    function sanitize(node){
      for (const child of Array.from(node.children)) {
        const name = child.nodeName.toLowerCase();
        if (!ALLOWED.has(name)) { child.remove(); continue; }
        for (const attr of Array.from(child.attributes)) {
          const n = attr.name.toLowerCase(), v = attr.value;
          if (n.startsWith('on')) child.removeAttribute(attr.name);
          else if ((n === 'href' || n === 'xlink:href') && !v.startsWith('#')) child.removeAttribute(attr.name);
          else if (/url\\(\\s*['"]?(?!#)/i.test(v)) child.removeAttribute(attr.name);
        }
        if (name === 'style') { child.textContent = child.textContent.replace(/@import[^;]*;?/g, '').replace(/url\\((?!\\s*['"]?#)[^)]*\\)/g, 'none'); }
        sanitize(child);
      }
    }
    function ensureKit(svg){
      let defs = svg.querySelector('defs');
      if (!defs) { defs = document.createElementNS(SVGNS, 'defs'); svg.insertBefore(defs, svg.firstChild); }
      const style = document.createElementNS(SVGNS, 'style');
      style.textContent = KIT;
      defs.appendChild(style);
      const markers = [['arrow', COLORS.ink]].concat(Object.entries(COLORS).map(([k, c]) => ['arrow-' + k, c]));
      for (const [id, color] of markers) {
        if (svg.querySelector('#' + id)) continue;
        const m = document.createElementNS(SVGNS, 'marker');
        m.setAttribute('id', id); m.setAttribute('viewBox', '0 0 10 10'); m.setAttribute('refX', '8.5'); m.setAttribute('refY', '5');
        m.setAttribute('markerWidth', '9'); m.setAttribute('markerHeight', '9'); m.setAttribute('markerUnits', 'userSpaceOnUse');
        m.setAttribute('orient', 'auto-start-reverse');
        const p = document.createElementNS(SVGNS, 'path');
        p.setAttribute('d', 'M0,0.8 L9.2,5 L0,9.2 Z'); p.setAttribute('fill', color); p.setAttribute('stroke', 'none');
        m.appendChild(p); defs.appendChild(m);
      }
      if (!svg.querySelector('#dot')) {
        const m = document.createElementNS(SVGNS, 'marker');
        m.setAttribute('id', 'dot'); m.setAttribute('viewBox', '0 0 10 10'); m.setAttribute('refX', '5'); m.setAttribute('refY', '5');
        m.setAttribute('markerWidth', '6'); m.setAttribute('markerHeight', '6'); m.setAttribute('markerUnits', 'userSpaceOnUse');
        const c = document.createElementNS(SVGNS, 'circle'); c.setAttribute('cx', '5'); c.setAttribute('cy', '5'); c.setAttribute('r', '4.5'); c.setAttribute('fill', COLORS.ink);
        m.appendChild(c); defs.appendChild(m);
      }
    }
    function applyDefaults(svg){
      for (const el of svg.querySelectorAll('path,line,polyline,polygon,rect,circle,ellipse')) {
        if (el.closest('marker') || el.closest('defs')) continue;
        if (!el.hasAttribute('stroke')) el.setAttribute('stroke', COLORS.ink);
        if (!el.hasAttribute('stroke-width')) el.setAttribute('stroke-width', '2');
        if (!el.hasAttribute('fill')) el.setAttribute('fill', 'none');
        if (!el.hasAttribute('stroke-linecap')) el.setAttribute('stroke-linecap', 'round');
        if (!el.hasAttribute('stroke-linejoin')) el.setAttribute('stroke-linejoin', 'round');
      }
      for (const el of svg.querySelectorAll('text')) {
        if (!el.hasAttribute('fill')) el.setAttribute('fill', COLORS.ink);
        if (!el.hasAttribute('font-size')) el.setAttribute('font-size', '14');
        el.setAttribute('stroke', 'none');
      }
    }
    function overlap(a, b){
      const x = Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x));
      const y = Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y));
      return x * y;
    }
    window.inkyDiagram = {
      prepare(text) {
        const problems = [];
        let source = String(text || '').trim();
        // Models often omit the namespace; without it nothing is an SVG element.
        if (!/<svg[^>]*\\sxmlns=/.test(source)) source = source.replace(/<svg\\b/, '<svg xmlns="http://www.w3.org/2000/svg"');
        if (/xlink:href/.test(source) && !/xmlns:xlink=/.test(source)) source = source.replace(/<svg\\b/, '<svg xmlns:xlink="http://www.w3.org/1999/xlink"');
        const doc = new DOMParser().parseFromString(source, 'image/svg+xml');
        const err = doc.querySelector('parsererror');
        if (err) return JSON.stringify({ ok: false, problems: ['the SVG is not valid XML: ' + err.textContent.trim().slice(0, 160)], width: 0, height: 0, minFontSize: 0, textCount: 0, svg: '' });
        const root = doc.documentElement;
        if (!root || root.nodeName.toLowerCase() !== 'svg') return JSON.stringify({ ok: false, problems: ['the root element must be <svg>'], width: 0, height: 0, minFontSize: 0, textCount: 0, svg: '' });
        sanitize(root);
        const host = document.getElementById('host');
        host.innerHTML = '';
        const svg = document.importNode(root, true);
        svg.setAttribute('xmlns', SVGNS);
        svg.setAttribute('class', ((svg.getAttribute('class') || '') + ' inky').trim());
        svg.removeAttribute('style');
        svg.setAttribute('width', '1100'); svg.setAttribute('height', '1100');
        host.appendChild(svg);
        ensureKit(svg);
        applyDefaults(svg);
        // Measure the content (all drawable children; markers/defs excluded by getBBox).
        let box;
        try { box = svg.getBBox(); } catch (e) { box = { x: 0, y: 0, width: 0, height: 0 }; }
        if (!(box.width > 4 && box.height > 4)) problems.push('the figure is empty or too small');
        // Text checks.
        const texts = Array.from(svg.querySelectorAll('text')).filter((t) => t.textContent.trim().length);
        const boxes = texts.map((t) => { try { return t.getBBox(); } catch (e) { return null; } });
        let minFont = 1000;
        for (const t of texts) minFont = Math.min(minFont, parseFloat(getComputedStyle(t).fontSize) || 14);
        for (let i = 0; i < texts.length; i++) for (let j = i + 1; j < texts.length; j++) {
          const a = boxes[i], b = boxes[j];
          if (!a || !b) continue;
          const o = overlap(a, b);
          if (o > 0.15 * Math.min(a.width * a.height, b.width * b.height)) {
            problems.push('labels "' + texts[i].textContent.trim().slice(0, 30) + '" and "' + texts[j].textContent.trim().slice(0, 30) + '" overlap');
          }
        }
        // Fit: content plus room for strokes and markers.
        const pad = 10;
        const vb = [box.x - pad, box.y - pad, box.width + 2 * pad, box.height + 2 * pad].map((v) => Math.round(v * 100) / 100);
        svg.setAttribute('viewBox', vb.join(' '));
        svg.setAttribute('width', String(vb[2]));
        svg.setAttribute('height', String(vb[3]));
        svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
        const out = new XMLSerializer().serializeToString(svg);
        return JSON.stringify({ ok: problems.length === 0, problems: problems.slice(0, 6), width: vb[2], height: vb[3],
          minFontSize: texts.length ? minFont : 0, textCount: texts.length, svg: out });
      }
    };
    </script></body></html>
    """

    private static func jsonString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
