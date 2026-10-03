import Foundation

/// The ONLY way the app talks to a model. Swap implementations in `InkyClientFactory`
/// (e.g. a future `ChatGPTInkyModelClient` using "Sign in with ChatGPT" tokens) without
/// touching the rest of the app.
protocol InkyModelClient: Sendable {
    /// Streams progress and decoded actions for one question about one page.
    /// The stream ends with exactly one `.completed` event, or throws `InkyClientError`.
    func respond(to request: InkyRequest) -> AsyncThrowingStream<InkyStreamEvent, Error>
}

/// Everything the model needs to answer, already localized (see `InkyLocalization`).
struct InkyRequest: Sendable {
    /// The student's question, typed or transcribed.
    var question: String
    /// Rendered page images with the coordinate grid overlay. First is the full page.
    var images: [InkyImage]
    /// Text lines on the page with normalized bounding boxes.
    var recognizedText: [RecognizedTextLine]
    /// Lassoed region the student wants to ask about, if any.
    var lassoRegion: NormRect?
    /// Page width / height, so the model can reason about proportions.
    var pageAspectRatio: Double
    var notebookTitle: String?
}

struct InkyImage: Sendable, Hashable {
    var pngData: Data
    /// Short caption sent before the image, e.g. "Full page".
    var caption: String
}

struct RecognizedTextLine: Codable, Sendable, Hashable {
    var text: String
    var box: NormRect
}

enum InkyStreamEvent: Sendable {
    /// Raw JSON text as it streams (useful for debugging / typing indicators).
    case textDelta(String)
    /// An action decoded as soon as its JSON object closed, before the response completes.
    case action(InkyAction)
    /// Final, fully decoded response.
    case completed(InkyResponse)
}

enum InkyClientError: LocalizedError, Equatable {
    case server(status: Int, message: String)
    case network(String)
    case modelFailed(String)
    case invalidResponse(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .server(let status, let message): "Inky couldn't answer (\(status)): \(message)"
        case .network(let message): "Inky can't reach the server. \(message)"
        case .modelFailed(let message): "Inky got confused: \(message)"
        case .invalidResponse(let message): "Inky's answer was malformed: \(message)"
        case .cancelled: "Cancelled"
        }
    }
}
