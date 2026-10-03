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
    /// Inky marks already on the page. The model sees them as short ids (`m1`, `m2`, …) in
    /// this order, so it can avoid overlapping them, refer to them, and remove them.
    var pageAnnotations: [InkyPageAnnotation] = []
    /// Earlier turns on this page, oldest first (see `InkyConversation`).
    var history: [InkyTurn] = []
    /// Empty answer boxes found on the page (`InkyLocalization.detectBlanks`).
    var blanks: [NormRect] = []
    /// Set by `ValidatingInkyModelClient` on its one retry: what was wrong last time.
    var correction: InkyCorrection?

    /// The short id the model sees for a page annotation.
    func shortID(for annotationID: UUID) -> String? {
        pageAnnotations.firstIndex { $0.id == annotationID }.map { "m\($0 + 1)" }
    }

    /// Resolves a short id from the model ("m2", also tolerates "M2" / "2") to the annotation id.
    func annotationID(forShortID raw: String) -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let uuid = UUID(uuidString: trimmed), pageAnnotations.contains(where: { $0.id == uuid }) { return uuid }
        let digits = trimmed.hasPrefix("m") ? String(trimmed.dropFirst()) : trimmed
        guard let n = Int(digits), n >= 1, n <= pageAnnotations.count else { return nil }
        return pageAnnotations[n - 1].id
    }
}

/// An Inky mark already on the page, as the model should see it.
struct InkyPageAnnotation: Sendable, Hashable {
    var id: UUID
    var action: InkyAction
    /// Where it is drawn now (after any user move), normalized page space.
    var bounds: NormRect
    var isHidden: Bool = false
    /// The question that produced it.
    var question: String?
}

/// One earlier exchange on the same page.
struct InkyTurn: Sendable, Hashable {
    var question: String
    /// What Inky returned (say/openSidebar included, so "why?" knows what was said).
    var actions: [InkyAction]
    /// Annotations that turn created (so "undo that" can find them).
    var createdAnnotationIDs: [UUID] = []
    var removedAnnotationIDs: [UUID] = []
    var date: Date = .now
}

/// Feedback for the retry after an invalid answer.
struct InkyCorrection: Sendable, Hashable {
    var problems: [String]
    /// Valid actions from the rejected answer that were already applied to the page.
    var alreadyApplied: [InkyAction]
}

struct InkyImage: Sendable, Hashable {
    var pngData: Data
    /// Short caption sent before the image, e.g. "Full page".
    var caption: String
}

struct RecognizedTextLine: Codable, Sendable, Hashable {
    var text: String
    var box: NormRect
    /// Left edge (normalized page x) of each whitespace-separated word, when known (Vision OCR).
    /// When nil, `InkyPromptBuilder` estimates them from character widths.
    var wordStarts: [Double]? = nil

    /// Word start positions: measured if available, else estimated proportionally by glyph width.
    var resolvedWordStarts: [(word: String, x: Double)] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let wordStarts, wordStarts.count == words.count {
            return Array(zip(words, wordStarts))
        }
        // Estimate: advance widths in em units for a typical proportional font.
        func width(_ c: Character) -> Double {
            if c == " " { return 0.28 }
            if "iljI.,:;'|!".contains(c) { return 0.25 }
            if "frt()[]/-".contains(c) { return 0.35 }
            if "mwMW".contains(c) { return 0.85 }
            if c.isUppercase { return 0.68 }
            if c.isNumber { return 0.56 }
            return 0.53
        }
        let total = text.reduce(0) { $0 + width($1) }
        guard total > 0 else { return [] }
        var result: [(String, Double)] = []
        var offset = 0.0
        var inWord = false
        var wordIndex = 0
        for c in text {
            if !c.isWhitespace && !inWord, wordIndex < words.count {
                result.append((words[wordIndex], box.x + box.width * offset / total))
                wordIndex += 1
            }
            inWord = !c.isWhitespace
            offset += width(c)
        }
        return result
    }
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
        case .server(429, let message): message
        case .server(let status, let message): "Inky couldn't answer (\(status)): \(message)"
        case .network(let message): "Inky can't reach the server. \(message)"
        case .modelFailed(let message): "Inky got confused: \(message)"
        case .invalidResponse(let message): "Inky's answer was malformed: \(message)"
        case .cancelled: "Cancelled"
        }
    }
}
