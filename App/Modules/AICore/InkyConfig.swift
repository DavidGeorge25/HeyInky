import Foundation

/// AI configuration. Every value can be overridden at launch with `-Key value`
/// arguments (UserDefaults argument domain), e.g. `-InkyProxyURL http://192.168.1.20:8787`.
enum InkyConfig {
    /// The one place the default model name lives (see evals/RESULTS.md for the comparison).
    static let defaultModelName = "gpt-5.4-mini"

    /// `-InkyModel gpt-5.4` overrides the model for A/B testing on device.
    static var modelName: String {
        UserDefaults.standard.string(forKey: "InkyModel").flatMap { $0.isEmpty ? nil : $0 } ?? defaultModelName
    }
    static let defaultReasoningEffort = "low"
    /// `-InkyReasoning medium` overrides it.
    static var reasoningEffort: String {
        UserDefaults.standard.string(forKey: "InkyReasoning").flatMap { $0.isEmpty ? nil : $0 } ?? defaultReasoningEffort
    }

    /// Requests where Inky draws or works something out need more thought (counting atoms,
    /// geometry, multi-step working); quick marks stay fast. An explicit override wins.
    static func reasoningEffort(for question: String) -> String {
        if let forced = UserDefaults.standard.string(forKey: "InkyReasoning"), !forced.isEmpty { return forced }
        let q = question.lowercased()
        return workKeywords.contains { q.contains($0) } ? "medium" : defaultReasoningEffort
    }

    static let workKeywords = [
        "draw", "sketch", "add the", "hydrogen", "lone pair", "mechanism", "arrow", "solve", "work out", "work it",
        "step", "explain", "why", "how does", "how do", "walk me", "show me how", "prove", "derive", "calculate", "balance",
        "new page", "diagram",
    ]
    /// Includes reasoning tokens; drawn answers (many shapes, worked steps) are long.
    static let maxOutputTokens = 12000

    static let defaultProxyURL = URL(string: "http://127.0.0.1:8787")!

    static var proxyURL: URL {
        if let string = UserDefaults.standard.string(forKey: "InkyProxyURL"), let url = URL(string: string) {
            return url
        }
        return defaultProxyURL
    }

    /// Optional shared secret matching INKY_PROXY_TOKEN in the proxy's .env.
    static var proxyToken: String? {
        UserDefaults.standard.string(forKey: "InkyProxyToken")
    }

    /// `-InkyUseMockClient YES` makes the app use canned responses (UI tests, offline demos).
    static var useMockClient: Bool {
        UserDefaults.standard.bool(forKey: "InkyUseMockClient")
    }
}

enum InkyClientFactory {
    /// Set once at launch by the app (`InkyDeepChecker`): checks that need RDKit or the diagram
    /// renderer, run on every action before it reaches the page.
    nonisolated(unsafe) static var deepCheck: ValidatingInkyModelClient.DeepCheck?

    /// Every client is wrapped in `ValidatingInkyModelClient` (checks + one retry).
    static func makeDefault() -> any InkyModelClient {
        if InkyConfig.useMockClient {
            return ValidatingInkyModelClient(base: MockInkyModelClient())
        }
        return ValidatingInkyModelClient(base: ProxyInkyModelClient(baseURL: InkyConfig.proxyURL, token: InkyConfig.proxyToken))
    }
}
