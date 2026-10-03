import Foundation

/// Turns OpenAI Responses API server-sent-event `data:` lines into `InkyStreamEvent`s.
/// Feed it lines with `consume(line:)`; call `finish()` at end of stream.
struct ResponsesStreamParser {
    private(set) var outputText = ""
    private var actionScanner = IncrementalActionScanner()
    private var completed = false

    /// Returns the events produced by one SSE line. Throws on model/stream errors.
    mutating func consume(line: String) throws -> [InkyStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return [] }

        switch type {
        case "response.output_text.delta":
            guard let delta = event["delta"] as? String else { return [] }
            outputText += delta
            var events: [InkyStreamEvent] = [.textDelta(delta)]
            for objectJSON in actionScanner.feed(delta) {
                if let action = try? JSONDecoder().decode(InkyAction.self, from: Data(objectJSON.utf8)) {
                    events.append(.action(action))
                }
            }
            return events
        case "response.completed":
            completed = true
            return [.completed(try decodeFinal())]
        case "response.incomplete":
            let reason = ((event["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String
            throw InkyClientError.modelFailed("response incomplete (\(reason ?? "unknown"))")
        case "response.failed":
            let message = ((event["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw InkyClientError.modelFailed(message ?? "response failed")
        case "error":
            // Mid-stream errors carry the message at the top level or under `error`
            // (e.g. rate limits: {"type":"error","error":{"code":"rate_limit_exceeded","message":…}}).
            let nested = event["error"] as? [String: Any]
            let code = (event["code"] as? String) ?? (nested?["code"] as? String)
            if code == "rate_limit_exceeded" {
                throw InkyClientError.server(status: 429, message: "Inky is getting too many questions right now. Try again in a moment.")
            }
            throw InkyClientError.modelFailed((event["message"] as? String) ?? (nested?["message"] as? String) ?? "stream error")
        case "response.refusal.delta", "response.refusal.done":
            if let refusal = (event["refusal"] as? String) ?? (event["delta"] as? String), type.hasSuffix("done") {
                throw InkyClientError.modelFailed(refusal)
            }
            return []
        default:
            return []
        }
    }

    /// Call when the byte stream ends. Produces `.completed` if the server never sent it.
    mutating func finish() throws -> [InkyStreamEvent] {
        if completed { return [] }
        guard !outputText.isEmpty else { throw InkyClientError.invalidResponse("empty response") }
        completed = true
        return [.completed(try decodeFinal())]
    }

    private func decodeFinal() throws -> InkyResponse {
        do {
            return try JSONDecoder().decode(InkyResponse.self, from: Data(outputText.utf8))
        } catch {
            throw InkyClientError.invalidResponse(String(describing: error))
        }
    }
}

/// Finds complete JSON objects inside the root `actions` array while JSON text is still
/// streaming, so the UI can render each action as soon as it is finished.
struct IncrementalActionScanner {
    private var buffer: [Character] = []
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var objectStart: Int?
    /// Depth at which action objects open: root `{` = 1, `actions` `[` = 2, action `{` = 3.
    private let actionDepth = 3

    mutating func feed(_ chunk: String) -> [String] {
        var found: [String] = []
        for ch in chunk {
            buffer.append(ch)
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"":
                inString = true
            case "{", "[":
                depth += 1
                if ch == "{" && depth == actionDepth { objectStart = buffer.count - 1 }
            case "}", "]":
                if ch == "}" && depth == actionDepth, let start = objectStart {
                    found.append(String(buffer[start...]))
                    objectStart = nil
                }
                depth -= 1
            default:
                break
            }
        }
        return found
    }
}
