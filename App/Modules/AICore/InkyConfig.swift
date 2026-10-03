import Foundation

/// AI configuration. Every value can be overridden at launch with `-Key value`
/// arguments (UserDefaults argument domain), e.g. `-InkyProxyURL http://192.168.1.20:8787`.
enum InkyConfig {
    /// The one place the model name lives.
    static let modelName = "gpt-5.4-mini"
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
    static func makeDefault() -> any InkyModelClient {
        if InkyConfig.useMockClient {
            return MockInkyModelClient()
        }
        return ProxyInkyModelClient(baseURL: InkyConfig.proxyURL, token: InkyConfig.proxyToken)
    }
}
