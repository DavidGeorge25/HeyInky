import SwiftUI
import WebKit

/// Messages the board sends back (see `post(...)` in inky-graph.js).
enum GraphWebMessage: Hashable, Sendable {
    case ready
    case rendered(curves: Int)
    case view(GraphAnalysis.Window, final: Bool)
    case point(index: Int, x: Double, y: Double, final: Bool)
    case tapFunction(Int)
    case error(String)

    init?(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        func number(_ key: String) -> Double? { (dict[key] as? NSNumber)?.doubleValue }
        let final = (dict["final"] as? Bool) ?? true
        switch type {
        case "ready": self = .ready
        case "rendered": self = .rendered(curves: Int(number("curves") ?? 0))
        case "view":
            guard let a = number("xMin"), let b = number("xMax"), let c = number("yMin"), let d = number("yMax") else { return nil }
            self = .view(GraphAnalysis.Window(xMin: a, xMax: b, yMin: c, yMax: d), final: final)
        case "point":
            guard let i = number("index"), let x = number("x"), let y = number("y") else { return nil }
            self = .point(index: Int(i), x: x, y: y, final: final)
        case "tapFunction":
            guard let i = number("index") else { return nil }
            self = .tapFunction(Int(i))
        case "error": self = .error(dict["message"] as? String ?? "Unknown error")
        default: return nil
        }
    }
}

/// Owns one offline WKWebView running JSXGraph and talks to it with JSON data only.
/// Scenes sent before the page is ready are queued; slider changes are sent as small patches.
@MainActor
final class GraphWebController: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var isReady = false
    private(set) var hasRendered = false
    private var pending: GraphScene?
    private var lastRendered: GraphScene?
    var onMessage: ((GraphWebMessage) -> Void)?

    static var pageURL: URL? { Bundle.main.url(forResource: "inky-graph", withExtension: "html") }

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.suppressesIncrementalRendering = true
        config.dataDetectorTypes = []
        let proxy = GraphScriptMessageProxy()
        config.userContentController.add(proxy, name: "inky")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 220), configuration: config)
        super.init()
        proxy.owner = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.accessibilityIdentifier = "inky.graph.board"
        load()
    }

    private func load() {
        guard let url = Self.pageURL else {
            onMessage?(.error("Graph resources are missing from the app bundle."))
            return
        }
        isReady = false
        hasRendered = false
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// Renders `scene`, rebuilding the board only when its structure changed.
    func show(_ scene: GraphScene) {
        guard isReady else { pending = scene; return }
        if let last = lastRendered, !Self.needsRebuild(from: last, to: scene) {
            if last.patch != scene.patch { call("inkyGraph.update(JSON.parse(json))", json: scene.json(scene.patch)) }
        } else {
            call("inkyGraph.render(JSON.parse(json))", json: scene.json(scene))
        }
        lastRendered = scene
    }

    /// Structure = everything except values the board already tracks live (params, view,
    /// dragged point positions) and the overlay a patch can replace.
    static func needsRebuild(from a: GraphScene, to b: GraphScene) -> Bool {
        a.functions != b.functions || a.labels != b.labels || a.axes != b.axes || a.theme != b.theme
            || abs(a.scale - b.scale) > 0.08 * max(a.scale, 0.01)
            || a.points.map { [$0.label ?? "", $0.draggable ? "1" : "0"] } != b.points.map { [$0.label ?? "", $0.draggable ? "1" : "0"] }
    }

    func setView(_ w: GraphAnalysis.Window) {
        let json = "{\"xMin\":\(w.xMin),\"xMax\":\(w.xMax),\"yMin\":\(w.yMin),\"yMax\":\(w.yMax)}"
        call("inkyGraph.setView(JSON.parse(json))", json: json)
    }

    func zoom(in zoomIn: Bool) {
        call("inkyGraph.zoom(f)", arguments: ["f": zoomIn ? 2 : 0.5])
    }

    /// Runs `body` in the page (for tests and diagnostics).
    func evaluate(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
    }

    private func call(_ body: String, json: String) {
        call(body, arguments: ["json": json])
    }

    private func call(_ body: String, arguments: [String: Any]) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { self?.onMessage?(.error(error.localizedDescription)) }
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let message = GraphWebMessage(body) else { return }
        switch message {
        case .ready:
            isReady = true
            lastRendered = nil
            if let scene = pending { pending = nil; show(scene) }
        case .rendered:
            hasRendered = true
        default:
            break
        }
        onMessage?(message)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Only the bundled page itself; links or redirects never load.
        guard let url = navigationAction.request.url, url.isFileURL, url.lastPathComponent == "inky-graph.html" else { return .cancel }
        return .allow
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let scene = lastRendered
        lastRendered = nil
        pending = scene
        load()
    }
}

/// WKUserContentController retains its handlers; this keeps the controller from leaking.
@MainActor
private final class GraphScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: GraphWebController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message.body)
    }
}

/// Hosts the controller's web view in SwiftUI. The view is created once per card and reused.
struct GraphWebView: UIViewRepresentable {
    let controller: GraphWebController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if controller.webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        let web = controller.webView
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(web)
    }
}
