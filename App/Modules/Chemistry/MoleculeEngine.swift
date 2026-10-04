import Foundation
import WebKit

enum MoleculeEngineError: LocalizedError, Equatable {
    case resourcesMissing
    case loadFailed(String)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .resourcesMissing: "The chemistry engine isn't bundled with the app."
        case .loadFailed(let message): "The chemistry engine didn't start: \(message)"
        case .engine(let message): message
        }
    }
}

/// The one RDKit instance for the whole app: a hidden `WKWebView` running RDKit MinimalLib
/// (WASM) from the app bundle. Cards ask it for depictions and SMARTS matches and draw the
/// result natively, so a page full of molecules costs one WASM instance, not one per card.
@MainActor
final class MoleculeEngine: NSObject, WKNavigationDelegate {
    static let shared = MoleculeEngine()

    private var webView: WKWebView?
    private var isLoaded = false
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var cache: [String: MoleculeAnalysis] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 64

    /// Depicts `smiles` (a molecule or a reaction "A.B>>C") and matches the library plus the
    /// caller's highlight/star patterns. Invalid SMILES come back as `ok == false`, not a throw.
    func analyze(smiles: String, highlightGroups: [String] = [], starGroups: [String] = []) async throws -> MoleculeAnalysis {
        let key = ([smiles] + highlightGroups + ["\u{1}"] + starGroups).joined(separator: "\u{0}")
        if let hit = cache[key] { return hit }

        let params: [String: Any] = [
            "smiles": smiles,
            "highlightGroups": highlightGroups,
            "starGroups": starGroups,
            "bondLength": 30,
        ]
        let json = try await call("return await window.inkyChem.analyze(params);", arguments: ["params": params])
        guard let text = json as? String, let data = text.data(using: .utf8) else {
            throw MoleculeEngineError.engine("The chemistry engine returned nothing.")
        }
        let analysis = try JSONDecoder().decode(MoleculeAnalysis.self, from: data)
        remember(analysis, for: key)
        return analysis
    }

    /// A molecule from a drawing's bond graph (atoms in drawing order). Coordinates only help
    /// RDKit perceive stereo/rings sensibly; units don't matter.
    func molecule(fromGraph atoms: [[String: Any]], bonds: [[String: Any]], highlightGroups: [String] = []) async throws -> GraphMolecule {
        let params: [String: Any] = ["atoms": atoms, "bonds": bonds, "highlightGroups": highlightGroups]
        let json = try await call("return await window.inkyChem.fromGraph(params);", arguments: ["params": params])
        guard let text = json as? String, let data = text.data(using: .utf8) else {
            throw MoleculeEngineError.engine("The chemistry engine returned nothing.")
        }
        return try JSONDecoder().decode(GraphMolecule.self, from: data)
    }

    /// Depicts each SMILES of a scheme, aligned to the first where the skeletons match.
    /// `keepRadicals`: the scheme is about single electrons (fishhook arrows); otherwise atoms the
    /// model bracketed only to number them keep their hydrogens.
    func scheme(steps: [String], keepRadicals: Bool = false) async throws -> SchemeAnalysis {
        let key = (["\u{2}scheme\(keepRadicals)"] + steps).joined(separator: "\u{0}")
        if let hit = schemeCache[key] { return hit }
        let params: [String: Any] = ["steps": steps, "bondLength": 30, "highlightGroups": [], "starGroups": [], "keepRadicals": keepRadicals]
        let json = try await call("return await window.inkyChem.scheme(params);", arguments: ["params": params])
        guard let text = json as? String, let data = text.data(using: .utf8) else {
            throw MoleculeEngineError.engine("The chemistry engine returned nothing.")
        }
        let result = try JSONDecoder().decode(SchemeAnalysis.self, from: data)
        schemeCache[key] = result
        return result
    }

    private var schemeCache: [String: SchemeAnalysis] = [:]

    /// The RDKit version (also a cheap readiness probe).
    func version() async throws -> String {
        (try await call("return await window.inkyChem.ready;", arguments: [:]) as? String) ?? "?"
    }

    private func remember(_ analysis: MoleculeAnalysis, for key: String) {
        cache[key] = analysis
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    private func call(_ body: String, arguments: [String: Any]) async throws -> Any? {
        let webView = try await loadedWebView()
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            throw MoleculeEngineError.engine((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
        }
    }

    private func loadedWebView() async throws -> WKWebView {
        if let webView, isLoaded { return webView }
        if webView == nil {
            guard ChemistryWebResources.root != nil else { throw MoleculeEngineError.resourcesMissing }
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: ChemistryWebResources.configuration())
            view.navigationDelegate = self
            #if DEBUG
            view.isInspectable = true
            #endif
            webView = view
            view.load(URLRequest(url: ChemistryWebResources.url("engine.html")))
        }
        try await withCheckedThrowingContinuation { waiters.append($0) }
        return webView!
    }

    private func finishLoading(_ result: Result<Void, any Error>) {
        if case .failure = result { webView = nil }
        isLoaded = (try? result.get()) != nil
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(with: result) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishLoading(.failure(MoleculeEngineError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finishLoading(.failure(MoleculeEngineError.loadFailed(error.localizedDescription)))
    }

    /// WebKit can kill a background web content process; start fresh on the next request.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.webView = nil
        isLoaded = false
    }
}
