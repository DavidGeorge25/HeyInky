import SwiftUI
import Testing
import WebKit
@testable import HeyInky

/// Runs the bundled JSXGraph page in a real WKWebView: it loads offline, draws presets,
/// interprets expression trees exactly like Swift, and can't eval or reach the network.
@MainActor
@Suite("Graph web board", .serialized)
struct GraphWebBridgeTests {
    final class Inbox {
        var messages: [GraphWebMessage] = []
    }

    /// A controller whose web view sits in an on-screen window (so it lays out and runs timers).
    func makeBoard(size: CGSize = CGSize(width: 480, height: 320)) async throws -> (GraphWebController, Inbox, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIViewController()
        window.isHidden = false
        let controller = GraphWebController()
        controller.webView.frame = window.bounds
        window.rootViewController?.view.addSubview(controller.webView)
        let inbox = Inbox()
        controller.onMessage = { inbox.messages.append($0) }
        try await waitUntil("page ready") { controller.isReady }
        return (controller, inbox, window)
    }

    func waitUntil(_ what: String, timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { throw WaitTimeout(what: what) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    struct WaitTimeout: Error, CustomStringConvertible {
        var what: String
        var description: String { "Timed out waiting for \(what)" }
    }

    func render(_ controller: GraphWebController, _ inbox: Inbox, _ scene: GraphScene) async throws -> Int {
        inbox.messages.removeAll()
        controller.show(scene)
        try await waitUntil("rendered") { inbox.messages.contains { if case .rendered = $0 { true } else if case .error = $0 { true } else { false } } }
        for m in inbox.messages { if case .error(let e) = m { Issue.record("board error: \(e)") } }
        let info = try await controller.evaluate("return inkyGraph.info()") as? [String: Any]
        // Every curve must actually be plotted (an eval-dependent JSXGraph path once left them empty).
        let points = (info?["curvePoints"] as? [NSNumber])?.map(\.intValue) ?? []
        #expect(points.allSatisfy { $0 > 50 }, "curve point counts \(points)")
        return (info?["curves"] as? NSNumber)?.intValue ?? -1
    }

    @Test func everyPresetRendersAndMatchesSwiftEvaluation() async throws {
        let (controller, inbox, window) = try await makeBoard()
        defer { window.isHidden = true }
        for preset in GraphPresets.all {
            let doc = GraphDocument(spec: preset.spec)
            let curves = try await render(controller, inbox, GraphScene(document: doc, theme: .light))
            #expect(curves == doc.spec.functions.count, "\(preset.id)")
            for i in doc.spec.functions.indices {
                let f = try #require(doc.evaluator(at: i))
                for k in 0...8 {
                    let x = doc.spec.xMin + (doc.spec.xMax - doc.spec.xMin) * Double(k) / 8
                    let expected = f(x)
                    guard expected.isFinite else { continue }
                    let js = try await controller.evaluate("return inkyGraph.evaluate(i, x)", arguments: ["i": i, "x": x]) as? NSNumber
                    let actual = try #require(js?.doubleValue, "\(preset.id) f\(i)(\(x))")
                    #expect(abs(actual - expected) <= 1e-9 * max(1, abs(expected)), "\(preset.id) f\(i)(\(x)): js \(actual) vs swift \(expected)")
                }
            }
        }
    }

    @Test(arguments: [
        "x^(1/3)", "Math.pow(x, 2/3)", "Math.round(x)", "x % 1.5", "x < 0 ? -x : x^2", "!(x > 1) || x == 2",
        "Math.max(x, 1, -2)", "Math.min(x, 0.5)", "Math.hypot(x, 3, 4)", "sec(x) + csc(x+1) + cot(x+2)",
        "Math.atan2(x, 2)", "ln(x^2 + 1) + log10(x^2 + 1) + log2(x^2 + 1)", "Math.sign(x) * Math.trunc(x)",
        "Math.sinh(x) - Math.cosh(x) + Math.tanh(x)", "2^-x", "-x^2", "Math.cbrt(x) + Math.expm1(x) + Math.log1p(x^2)",
    ])
    func javaScriptInterpreterMatchesSwift(_ source: String) async throws {
        let (controller, _, window) = try await makeBoard(size: CGSize(width: 100, height: 100))
        defer { window.isHidden = true }
        let expr = try GraphExpr.parse(source)
        let tree = String(decoding: try JSONEncoder().encode(expr.wire), as: UTF8.self)
        for x in stride(from: -3.0, through: 3.0, by: 0.37) {
            let expected = expr.evaluate(x: x, params: [])
            guard expected.isFinite else { continue }
            let js = try await controller.evaluate("return inkyGraph.evaluateTree(JSON.parse(t), x, [])", arguments: ["t": tree, "x": x]) as? NSNumber
            let actual = try #require(js?.doubleValue)
            #expect(abs(actual - expected) <= 1e-12 * max(1, abs(expected)), "\(source) at \(x): js \(actual) vs swift \(expected)")
        }
    }

    @Test func slidersPatchWithoutRebuilding() async throws {
        let (controller, inbox, window) = try await makeBoard()
        defer { window.isHidden = true }
        var doc = GraphDocument(spec: GraphPresets.michaelisMenten.spec)
        _ = try await render(controller, inbox, GraphScene(document: doc, theme: .light))
        doc.setParamValue(4, named: "Vmax")
        inbox.messages.removeAll()
        controller.show(GraphScene(document: doc, theme: .light))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!inbox.messages.contains { if case .rendered = $0 { true } else { false } }, "a param change is a patch, not a rebuild")
        let value = try await controller.evaluate("return inkyGraph.evaluate(0, 2)") as? NSNumber
        #expect(value?.doubleValue == 2, "Vmax·Km/(Km+Km) = 4/2")
    }

    @Test func pageCannotEvalOrReachTheNetwork() async throws {
        let (controller, _, window) = try await makeBoard(size: CGSize(width: 100, height: 100))
        defer { window.isHidden = true }
        let evalResult = try await controller.evaluate("try { eval('1+1'); return 'allowed' } catch (e) { return 'blocked' }") as? String
        #expect(evalResult == "blocked")
        let functionResult = try await controller.evaluate("try { new Function('return 1')(); return 'allowed' } catch (e) { return 'blocked' }") as? String
        #expect(functionResult == "blocked")
        let fetchResult = try await controller.evaluate("try { await fetch('https://example.com'); return 'allowed' } catch (e) { return 'blocked' }") as? String
        #expect(fetchResult == "blocked")
        let badTree = try await controller.evaluate("try { inkyGraph.evaluateTree(['f','constructor',[['x']]], 1, []); return 'allowed' } catch (e) { return 'blocked' }") as? String
        #expect(badTree == "blocked", "unknown function names in trees are refused")
    }

    @Test func boardSnapshotShowsTheCurve() async throws {
        let (controller, inbox, window) = try await makeBoard()
        defer { window.isHidden = true }
        let doc = GraphDocument(spec: GraphPresets.harmonic.spec)
        // Curves only, so key-point dots can't stand in for a missing curve.
        let scene = GraphScene(document: doc, theme: .light, options: .init(asymptotes: false, features: false))
        _ = try await render(controller, inbox, scene)
        try await Task.sleep(for: .milliseconds(300))
        let config = WKSnapshotConfiguration()
        let image = try await controller.webView.takeSnapshot(configuration: config)
        let pixels = try #require(RGBAImage(image))
        let indigo = pixels.count { r, g, b in abs(r - 91) < 35 && abs(g - 91) < 35 && abs(b - 214) < 35 }
        #expect(indigo > 200, "x(t) curve drawn in indigo (\(indigo) px)")
        let teal = pixels.count { r, g, b in abs(r - 18) < 35 && abs(g - 165) < 35 && abs(b - 148) < 35 }
        #expect(teal > 200, "v(t) curve drawn in teal (\(teal) px)")
    }
}
