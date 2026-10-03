import Foundation

/// Builds the OpenAI Responses API request body for an `InkyRequest`.
/// Prompt and schema are bundled from /shared so the proxy smoke test uses the same ones.
enum InkyPromptBuilder {
    static func systemPrompt(bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "inky_system_prompt", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            preconditionFailure("inky_system_prompt.md missing from bundle")
        }
        return text
    }

    /// The schema file's exact text. Sent verbatim: strict structured outputs generate
    /// properties in schema order, and a Swift dictionary round trip would shuffle keys
    /// (putting `type` after other fields makes most actions unreachable for the model).
    static func actionSchemaText(bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "inky_actions.schema", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            preconditionFailure("inky_actions.schema.json missing from bundle")
        }
        return text
    }

    /// The action schema as a JSON object (for inspection and tests; key order is lost).
    static func actionSchema(bundle: Bundle = .main) -> [String: Any] {
        let data = Data(actionSchemaText(bundle: bundle).utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static let schemaPlaceholder = "__INKY_ACTION_SCHEMA__"

    static func userText(for request: InkyRequest) -> String {
        var lines: [String] = []
        if let title = request.notebookTitle, !title.isEmpty {
            lines.append("Notebook: \(title)")
        }
        lines.append(String(format: "Page aspect ratio (width/height): %.3f", request.pageAspectRatio))
        if let lasso = request.lassoRegion {
            lines.append("The student lassoed this region: \(format(lasso))")
        }
        if request.recognizedText.isEmpty {
            lines.append("Recognized text: none")
        } else {
            lines.append("Recognized text (normalized x, y, width, height):")
            for line in request.recognizedText.prefix(150) {
                lines.append("\(format(line.box)) \"\(line.text)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Request body as a dictionary. The schema is a placeholder here; use `bodyData`.
    static func body(for request: InkyRequest, model: String = InkyConfig.modelName, bundle: Bundle = .main) -> [String: Any] {
        var content: [[String: Any]] = [["type": "input_text", "text": userText(for: request)]]
        for image in request.images {
            content.append(["type": "input_text", "text": image.caption])
            content.append([
                "type": "input_image",
                "image_url": "data:image/png;base64,\(image.pngData.base64EncodedString())",
                "detail": "high",
            ])
        }
        content.append(["type": "input_text", "text": "Student: \(request.question)"])

        return [
            "model": model,
            "instructions": systemPrompt(bundle: bundle),
            "input": [["role": "user", "content": content]],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "inky_actions",
                    "strict": true,
                    "schema": schemaPlaceholder,
                ],
            ],
            "reasoning": ["effort": InkyConfig.reasoningEffort],
            "max_output_tokens": InkyConfig.maxOutputTokens,
            "stream": true,
        ]
    }

    /// Serialized request body with the schema spliced in verbatim (order preserved).
    static func bodyData(for request: InkyRequest, model: String = InkyConfig.modelName, bundle: Bundle = .main) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: body(for: request, model: model, bundle: bundle))
        let json = String(decoding: data, as: UTF8.self)
        let spliced = json.replacingOccurrences(of: "\"\(schemaPlaceholder)\"", with: actionSchemaText(bundle: bundle))
        return Data(spliced.utf8)
    }

    static func format(_ r: NormRect) -> String {
        String(format: "[%.3f, %.3f, %.3f, %.3f]", r.x, r.y, r.width, r.height)
    }
}
