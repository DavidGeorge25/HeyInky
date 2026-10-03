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
        let orientation = request.pageAspectRatio < 1 ? "portrait" : "landscape"
        lines.append(String(format: "Page aspect ratio (width/height): %.3f (%@)", request.pageAspectRatio, orientation))
        if let lasso = request.lassoRegion {
            lines.append("The student lassoed this region: \(format(lasso)). Their request is about what is inside it.")
        }

        lines.append("")
        if request.recognizedText.isEmpty {
            lines.append("Recognized text: none (read the image).")
        } else {
            lines.append("Recognized text lines [x, y, width, height] (OCR of handwriting may contain mistakes):")
            for line in request.recognizedText.prefix(maxTextLines) {
                lines.append("\(format(line.box)) \"\(line.text)\"")
            }
            if request.recognizedText.count > maxTextLines {
                lines.append("… \(request.recognizedText.count - maxTextLines) more lines not listed.")
            }
        }

        lines.append("")
        if request.pageAnnotations.isEmpty {
            lines.append("Inky marks already on the page: none.")
        } else {
            lines.append("Inky marks already on the page (outlined in orange with their id in the image):")
            for (index, mark) in request.pageAnnotations.enumerated() {
                var line = "m\(index + 1): \(describe(mark.action)) at \(format(mark.bounds))"
                if mark.isHidden { line += " (hidden by the student)" }
                if let q = mark.question, !q.isEmpty { line += " — made for \"\(clip(q, 80))\"" }
                lines.append(line)
            }
        }

        if !request.history.isEmpty {
            lines.append("")
            lines.append("Earlier in this conversation about this page (oldest first):")
            for (index, turn) in request.history.enumerated() {
                lines.append("\(index + 1). Student: \"\(clip(turn.question, 200))\"")
                let created = turn.createdAnnotationIDs.compactMap(request.shortID(for:))
                var did = turn.actions.map { describe($0, long: true) }
                if !turn.removedAnnotationIDs.isEmpty { did.insert("removed \(turn.removedAnnotationIDs.count) mark(s)", at: 0) }
                lines.append("   Inky: \(did.isEmpty ? "nothing" : did.joined(separator: "; "))")
                if !created.isEmpty {
                    lines.append("   Marks from that turn still on the page: \(created.joined(separator: ", "))")
                } else if turn.actions.contains(where: \.isPageAnnotation) {
                    lines.append("   Marks from that turn: none left on the page")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func questionText(for request: InkyRequest) -> String {
        var text = "Student: \(request.question)"
        if let correction = request.correction {
            text += "\n\nYour previous answer to this was rejected:"
            for problem in correction.problems { text += "\n- \(problem)" }
            if correction.alreadyApplied.isEmpty {
                text += "\nReturn a corrected, complete answer."
            } else {
                text += "\nThese actions from it were valid and are already applied; do not repeat them:"
                for action in correction.alreadyApplied { text += "\n- \(describe(action))" }
                text += "\nReturn only the corrected or missing actions."
            }
        }
        return text
    }

    static let maxTextLines = 150

    /// Compact one-line description of an action for context lists.
    static func describe(_ action: InkyAction, long: Bool = false) -> String {
        switch action {
        case .highlight(let a):
            return "\(a.color.rawValue) highlight \(format(a.region))" + (a.note.map { " note \"\($0)\"" } ?? "")
        case .circle(let a): return "circle \(format(a.region))"
        case .star(let a): return String(format: "star at (%.3f, %.3f)", a.point.x, a.point.y)
        case .label(let a): return String(format: "label \"%@\" at (%.3f, %.3f)", clip(a.text, 60), a.anchor.x, a.anchor.y)
        case .fillText(let a): return "wrote \"\(clip(a.text, 80))\" in \(format(a.region))"
        case .insertMoleculeCard(let a):
            return "molecule card \(a.smiles)" + (a.caption.map { " (\(clip($0, 60)))" } ?? "")
        case .insertGraphCard(let a):
            let fns = a.spec.functions.map(\.expression).joined(separator: ", ")
            return "graph card \(a.spec.title.map { "\"\(clip($0, 60))\" " } ?? "")y = \(clip(fns, 120))"
        case .openSidebar(let a):
            return "explained in the sidebar: \"\(clip(a.markdown.replacingOccurrences(of: "\n", with: " "), long ? 500 : 120))\""
        case .say(let a): return "said \"\(clip(a.text, 200))\""
        }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
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
        content.append(["type": "input_text", "text": questionText(for: request)])

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
