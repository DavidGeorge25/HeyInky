import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled `ChemistryWeb` folder (RDKit.js + WASM, Ketcher, the SMARTS library)
/// to web views under `inkychem://app/…`. A custom scheme instead of `file://` because
/// WebKit only streams WASM and lets `fetch()` read local files when they come from a
/// scheme with real MIME types; nothing is ever fetched from the network.
@MainActor
final class ChemistryWebResources: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "inkychem"
    static let shared = ChemistryWebResources()

    /// Root of the bundled folder (a folder reference in project.yml).
    nonisolated static var root: URL? {
        Bundle.main.url(forResource: "ChemistryWeb", withExtension: nil)
    }

    nonisolated static func url(_ path: String) -> URL {
        URL(string: "\(scheme)://app/\(path)")!
    }

    /// A configuration whose web views can load `inkychem://` URLs.
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(shared, forURLScheme: scheme)
        config.suppressesIncrementalRendering = false
        return config
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.fileURL(for: url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        do {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": Self.mimeType(for: file),
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "max-age=31536000",
            ])!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// Maps `inkychem://app/<path>` to a file inside the bundled folder; refuses anything
    /// that would escape it.
    nonisolated static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme, let root = root?.standardizedFileURL else { return nil }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "engine.html" }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    nonisolated static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "wasm": "application/wasm"
        case "js": "text/javascript; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "html": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        default: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
