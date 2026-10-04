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
            lines.append("Recognized text lines [x, y, width, height] (OCR of handwriting may contain mistakes), each followed by where its words start (word@x):")
            for line in request.recognizedText.prefix(maxTextLines) {
                lines.append("\(format(line.box)) \"\(line.text)\"")
                let words = line.resolvedWordStarts
                if words.count >= 2 && request.recognizedText.count <= maxLinesWithWords {
                    let list = words.map { "\($0.word)@\(String(format: "%.3f", $0.x).replacingOccurrences(of: "0.", with: "."))" }
                    lines.append("   " + list.joined(separator: " "))
                }
            }
            if request.recognizedText.count > maxTextLines {
                lines.append("… \(request.recognizedText.count - maxTextLines) more lines not listed.")
            }
        }

        if !request.blanks.isEmpty {
            lines.append("")
            lines.append("Empty boxes detected on the page (answer blanks; use these exact boxes for fillText):")
            for blank in request.blanks { lines.append(format(blank)) }
        }

        if !request.inkPaths.isEmpty {
            lines.append("")
            lines.append("Pen strokes on the page (not handwriting), simplified to their corner points (x, y) in drawing order. In a skeletal structure every corner and free line end is a carbon; attach drawings to these exact points:")
            for (index, path) in request.inkPaths.prefix(maxInkPaths).enumerated() {
                lines.append("s\(index + 1): " + path.map { String(format: "(%.3f, %.3f)", $0.x, $0.y) }.joined(separator: " "))
            }
            if !request.inkAtoms.isEmpty {
                lines.append("Junctions of those strokes (atoms of a skeletal structure) and how many lines meet at each — a carbon there has 4 − that many hydrogens (a double bond drawn as two lines counts 2):")
                lines.append(request.inkAtoms.prefix(maxInkPaths).enumerated().map { i, atom in
                    String(format: "a%d (%.3f, %.3f) %d line%@", i + 1, atom.point.x, atom.point.y, atom.bonds, atom.bonds == 1 ? "" : "s")
                }.joined(separator: "; "))
            }
        }

        if !request.structures.isEmpty {
            lines.append("")
            lines.append(structureText(request.structures))
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

    /// Recognized structures as an atom/bond table the model can refer to by id.
    static func structureText(_ structures: [PageStructure]) -> String {
        var lines = ["Chemical structures recognized on the page (positions are exact — mark them with `annotateStructure` by atom id; the app places everything precisely):"]
        for s in structures.prefix(6) {
            let source = switch s.source {
            case .image: "in an image"
            case .ink: "in the student's ink"
            case .pdf: "on the slide"
            }
            var head = "\(s.id) — drawn \(source) at \(format(s.region))"
            head += s.smiles.map { ", SMILES \($0)" } ?? ", SMILES unverified (RDKit couldn't confirm the drawing)"
            lines.append(head)
            let atoms = s.atoms.prefix(60).map { atom -> String in
                var t = "\(atom.id) \(atom.element)"
                if let label = atom.label { t += atom.unsure ? " \"\(label)\"?" : " \"\(label)\"" }
                t += String(format: " (%.3f, %.3f)", atom.point.x, atom.point.y)
                if atom.hiddenHydrogens > 0 { t += " +\(atom.hiddenHydrogens)H" }
                if atom.charge != 0 { t += atom.charge > 0 ? " charge +\(atom.charge)" : " charge \(atom.charge)" }
                return t
            }
            lines.append("  atoms: " + atoms.joined(separator: "; "))
            let bonds = s.bonds.prefix(80).map { b -> String in
                let symbol = b.order == 2 ? "=" : b.order == 3 ? "≡" : "–"
                return "\(s.atoms[b.a].id)\(symbol)\(s.atoms[b.b].id)"
            }
            lines.append("  bonds: " + bonds.joined(separator: " "))
            let hidden = s.atoms.reduce(0) { $0 + $1.hiddenHydrogens }
            lines.append("  hidden hydrogens in total: \(hidden)")
            if s.atoms.contains(where: \.unsure) {
                lines.append("  Labels marked ? were hard to read: check them in the image and fix any wrong ones with `relabel`.")
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
    static let maxInkPaths = 80
    /// Word positions roughly double the text tokens; skip them on very dense pages.
    static let maxLinesWithWords = 60

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
        case .draw(let a):
            let texts = a.shapes.compactMap { $0.kind == .text ? $0.text : nil }.joined(separator: " / ")
            let kinds = Dictionary(grouping: a.shapes.filter { $0.kind != .text }, by: \.kind).map { "\($0.value.count) \($0.key.rawValue)" }.sorted().joined(separator: ", ")
            return "drew" + (a.caption.map { " \"\(clip($0, 60))\"" } ?? "") + (kinds.isEmpty ? "" : " (\(kinds))")
                + (texts.isEmpty ? "" : " writing \"\(clip(texts, long ? 300 : 80))\"")
        case .annotateStructure(let a):
            var parts: [String] = []
            if !a.hydrogens.isEmpty { parts.append("hydrogens on \(a.hydrogens.joined(separator: ","))") }
            if !a.lonePairs.isEmpty { parts.append("lone pairs on \(a.lonePairs.joined(separator: ","))") }
            if !a.charges.isEmpty { parts.append(a.charges.map { "\($0.text) on \($0.atom)" }.joined(separator: ", ")) }
            if !a.highlights.isEmpty { parts.append("highlighted " + a.highlights.map { $0.group ?? $0.atoms.joined(separator: ",") }.joined(separator: "; ")) }
            if !a.labels.isEmpty { parts.append("labels " + a.labels.map { "\"\($0.text)\" at \($0.atom)" }.joined(separator: ", ")) }
            if !a.arrows.isEmpty { parts.append("arrows " + a.arrows.map { "\($0.from)→\($0.to)" }.joined(separator: ", ")) }
            return "marked \(a.structure): " + (parts.isEmpty ? "nothing" : parts.joined(separator: "; "))
        case .insertChemScheme(let a):
            let kinds = a.connectors.map(\.kind.rawValue).joined(separator: "/")
            return "chemistry figure" + (a.title.map { " \"\(clip($0, 60))\"" } ?? "") + " (\(a.steps.count) structures\(kinds.isEmpty ? "" : ", \(kinds)")): " + clip(a.steps.map(\.smiles).joined(separator: " | "), long ? 400 : 120) + " at \(format(a.near))"
        case .insertMath(let a):
            return "typeset math" + (a.title.map { " \"\(clip($0, 60))\"" } ?? "") + ": " + clip(a.lines.map(\.latex).joined(separator: " ; "), long ? 400 : 140) + " at \(format(a.near))"
        case .insertPractice(let a):
            return "practice card" + (a.title.map { " \"\(clip($0, 60))\"" } ?? "") + " with \(a.problems.count) problem(s): " + clip(a.problems.map(\.prompt).joined(separator: " | "), long ? 400 : 120)
        case .insertDiagram(let a):
            return "diagram" + (a.title.map { " \"\(clip($0, 60))\"" } ?? "") + " at \(format(a.near))"
        case .addPage(let a):
            return "added a new \(a.paper.rawValue) page"
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
            "reasoning": ["effort": InkyConfig.reasoningEffort(for: request.question)],
            "max_output_tokens": InkyConfig.maxOutputTokens,
            // Same prefix (instructions + schema) on every request: route them to the same cache.
            "prompt_cache_key": "inky-v3",
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
