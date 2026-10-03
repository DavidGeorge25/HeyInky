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
    static let reasoningEffort = "low"
    static let maxOutputTokens = 4000

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
    /// Every client is wrapped in `ValidatingInkyModelClient` (checks + one retry).
    static func makeDefault() -> any InkyModelClient {
        if InkyConfig.useMockClient {
            return ValidatingInkyModelClient(base: MockInkyModelClient())
        }
        return ValidatingInkyModelClient(base: ProxyInkyModelClient(baseURL: InkyConfig.proxyURL, token: InkyConfig.proxyToken))
    }
}
