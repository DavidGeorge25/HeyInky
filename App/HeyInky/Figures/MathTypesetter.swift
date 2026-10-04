import Foundation
import WebKit

/// Typesets `insertMath` lines with MathJax (bundled offline, TeX → SVG paths, mhchem included)
/// into one SVG: lines aligned at their first relation (=, ≤, →, ⇒ …), gray step notes in a
/// right column, the final line optionally boxed. The SVG then goes through `DiagramEngine`
/// (fit, checks, vector PDF) like any figure.
@MainActor
final class MathTypesetter: NSObject, WKNavigationDelegate {
    static let shared = MathTypesetter()

    struct Typeset: Codable, Sendable {
        var ok: Bool
        var problems: [String]
        var svg: String
    }

    private var webView: WKWebView?
    private var loaded = false
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var cache: [String: Typeset] = [:]

    func typeset(_ action: InsertMathAction) async throws -> Typeset {
        let key = action.lines.map { $0.latex + "\u{1}" + ($0.note ?? "") }.joined(separator: "\u{0}") + "\(action.align)\(action.boxLast)"
        if let hit = cache[key] { return hit }
        let view = try await engine()
        let lines: [[String: Any]] = action.lines.map { ["latex": $0.latex, "note": $0.note ?? ""] }
        let raw = try await view.callAsyncJavaScript(
            "return await window.inkyMath.render(lines, align, boxLast);",
            arguments: ["lines": lines, "align": action.align, "boxLast": action.boxLast], in: nil, contentWorld: .page
        )
        guard let text = raw as? String, let data = text.data(using: .utf8) else { throw DiagramEngine.EngineError.script("no math result") }
        let result = try JSONDecoder().decode(Typeset.self, from: data)
        cache[key] = result
        return result
    }

    private func engine() async throws -> WKWebView {
        if let webView, loaded { return webView }
        if webView == nil {
            guard let url = Bundle.main.url(forResource: "mathjax-tex-svg-full", withExtension: "js"),
                  let mathjax = try? String(contentsOf: url, encoding: .utf8) else {
                throw DiagramEngine.EngineError.load("MathJax isn't bundled")
            }
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), configuration: WKWebViewConfiguration())
            view.navigationDelegate = self
            #if DEBUG
            view.isInspectable = true
            #endif
            webView = view
            let html = Self.pageHead + "<script>" + mathjax + "</script>" + Self.pageScript
            view.loadHTMLString(html, baseURL: nil)
        }
        try await withCheckedThrowingContinuation { waiters.append($0) }
        return webView!
    }

    private func finish(_ result: Result<Void, any Error>) {
        loaded = (try? result.get()) != nil
        if !loaded { webView = nil }
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(with: result) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { self.webView = nil; loaded = false }

    private static let pageHead = """
    <!doctype html><html><head><meta charset="utf-8"><style>body{margin:0;font-size:20px}#work{position:absolute;left:0;top:0}</style>
    <script>window.MathJax = { svg: { fontCache: 'none' }, startup: { typeset: false } };</script></head><body><div id="work"></div>
    """

    private static let pageScript = """
    <script>
    const NS = 'http://www.w3.org/2000/svg';
    // First relation outside braces: where the line aligns.
    const RELS = ['\\\\Longrightarrow', '\\\\Rightarrow', '\\\\rightarrow', '\\\\approx', '\\\\equiv', '\\\\propto', '\\\\leq', '\\\\geq', '\\\\neq', '\\\\le', '\\\\ge', '\\\\to', '=', '<', '>'];
    function splitAtRelation(tex) {
      let depth = 0;
      for (let i = 0; i < tex.length; i++) {
        const c = tex[i];
        if (c === '{') depth++;
        else if (c === '}') depth--;
        else if (depth === 0) {
          for (const r of RELS) {
            if (tex.startsWith(r, i) && !(r.startsWith('\\\\') && /[a-zA-Z]/.test(tex[i + r.length] || ''))) {
              if (r === '<' || r === '>') { if (tex[i - 1] === '\\\\') continue; }
              return [tex.slice(0, i), tex.slice(i)];
            }
          }
        }
      }
      return null;
    }
    async function piece(tex, problems, lineNo) {
      if (!tex.trim()) return null;
      const node = MathJax.tex2svg(tex, { display: false });
      const err = node.querySelector('[data-mjx-error]') || node.querySelector('merror');
      if (err) problems.push('LaTeX error in line ' + (lineNo + 1) + ': ' + (err.getAttribute('data-mjx-error') || err.textContent || 'invalid TeX').slice(0, 120));
      document.getElementById('work').appendChild(node);
      const svg = node.querySelector('svg');
      const r = svg.getBoundingClientRect();
      const out = { svg, w: r.width, h: r.height, baseline: 0 };
      // Distance from the top to the baseline (MathJax sets vertical-align in ex).
      const va = parseFloat((svg.style.verticalAlign || '0').replace('ex', '')) || 0;
      const ex = 8.6;  // px per ex at 20px font
      out.depth = -va * ex;
      out.ascent = r.height - out.depth;
      return out;
    }
    window.inkyMath = {
      async render(lines, align, boxLast) {
        await MathJax.startup.promise;
        const problems = [];
        document.getElementById('work').innerHTML = '';
        const rows = [];
        for (let k = 0; k < lines.length; k++) {
          const tex = String(lines[k].latex || '');
          const parts = align ? splitAtRelation(tex) : null;
          if (parts) {
            rows.push({ left: await piece(parts[0], problems, k), right: await piece(parts[1], problems, k), note: lines[k].note });
          } else {
            rows.push({ left: null, right: await piece(tex, problems, k), note: lines[k].note, full: true });
          }
        }
        const leftW = Math.max(0, ...rows.map((r) => (r.left && !r.full) ? r.left.w : 0));
        const gap = 6, rowGap = 14, noteGap = 28;
        const out = document.createElementNS(NS, 'svg');
        let y = 0, maxRight = 0;
        const placed = [];
        for (const row of rows) {
          const ascent = Math.max(row.left ? row.left.ascent : 0, row.right ? row.right.ascent : 0, 12);
          const depth = Math.max(row.left ? row.left.depth : 0, row.right ? row.right.depth : 0, 4);
          const base = y + ascent;
          const put = (p, x) => {
            const s = p.svg.cloneNode(true);
            s.setAttribute('x', String(x)); s.setAttribute('y', String(base - p.ascent));
            s.setAttribute('width', String(p.w)); s.setAttribute('height', String(p.h));
            s.removeAttribute('style');
            out.appendChild(s);
          };
          let rightX = row.full ? 0 : leftW + (row.left ? gap : 0);
          if (row.left && !row.full) put(row.left, leftW - row.left.w);
          if (row.right) put(row.right, rightX);
          const rowRight = rightX + (row.right ? row.right.w : 0);
          placed.push({ base, ascent, depth, rightX, rowRight, row });
          maxRight = Math.max(maxRight, rowRight);
          y = base + depth + rowGap;
        }
        for (const p of placed) {
          if (!p.row.note) continue;
          const t = document.createElementNS(NS, 'text');
          t.setAttribute('x', String(maxRight + noteGap)); t.setAttribute('y', String(p.base));
          t.setAttribute('font-size', '14'); t.setAttribute('fill', '#8A8A94');
          t.textContent = p.row.note;
          out.appendChild(t);
        }
        if (boxLast && placed.length) {
          const p = placed[placed.length - 1];
          // The whole answer line, left side included.
          const x0 = (!p.row.full && p.row.left) ? leftW - p.row.left.w : p.rightX;
          const r = document.createElementNS(NS, 'rect');
          r.setAttribute('x', String(x0 - 6)); r.setAttribute('y', String(p.base - p.ascent - 6));
          r.setAttribute('width', String(p.rowRight - x0 + 12)); r.setAttribute('height', String(p.ascent + p.depth + 12));
          r.setAttribute('rx', '6'); r.setAttribute('fill', 'none'); r.setAttribute('stroke', '#5B5BD6'); r.setAttribute('stroke-width', '1.6');
          out.appendChild(r);
        }
        out.setAttribute('xmlns', NS);
        out.setAttribute('viewBox', '0 0 ' + Math.ceil(maxRight + 400) + ' ' + Math.ceil(y));
        return JSON.stringify({ ok: problems.length === 0, problems, svg: new XMLSerializer().serializeToString(out) });
      }
    };
    </script></body></html>
    """
}
