import Foundation

/// Offline client returning canned actions. Used by tests, UI tests and demos
/// (`-InkyUseMockClient YES`). Picks a response from keywords in the question.
struct MockInkyModelClient: InkyModelClient {
    var delay: Duration = .milliseconds(300)
    /// When set, always returns these actions.
    var fixedActions: [InkyAction]?

    func respond(to request: InkyRequest) -> AsyncThrowingStream<InkyStreamEvent, Error> {
        let actions = fixedActions ?? Self.cannedActions(for: request)
        let delay = self.delay
        let removals = fixedActions == nil ? Self.cannedRemovals(for: request) : []
        return AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: delay)
                if Task.isCancelled {
                    continuation.finish(throwing: InkyClientError.cancelled)
                    return
                }
                for action in actions { continuation.yield(.action(action)) }
                continuation.yield(.completed(InkyResponse(removeAnnotations: removals, actions: actions)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A short C–H line pointing away from each corner of the first pen stroke, with an "H".
    static func mockHydrogens(_ request: InkyRequest) -> DrawAction {
        let path = request.inkPaths.first ?? [NormPoint(x: 0.4, y: 0.4), NormPoint(x: 0.5, y: 0.45), NormPoint(x: 0.6, y: 0.4)]
        let aspect = request.pageAspectRatio
        var shapes: [DrawAction.Shape] = []
        for (i, c) in path.enumerated() {
            let prev = path[max(0, i - 1)], next = path[min(path.count - 1, i + 1)]
            var dx = (c.x - prev.x) + (c.x - next.x), dy = ((c.y - prev.y) + (c.y - next.y)) / aspect
            let length = max(hypot(dx, dy), 0.0001)
            dx /= length; dy /= length
            let end = NormPoint(x: c.x + 0.035 * dx, y: c.y + 0.035 * dy * aspect)
            shapes.append(.init(kind: .line, points: [c, end], text: nil, size: .medium))
            shapes.append(.init(kind: .text, points: [NormPoint(x: end.x + dx * 0.004 - 0.008, y: end.y + dy * 0.004 - 0.012)], text: "H", size: .small))
        }
        return DrawAction(ink: .pen, color: .indigo, shapes: shapes, caption: "hydrogens")
    }

    /// "undo that" removes the marks the previous turn created.
    static func cannedRemovals(for request: InkyRequest) -> [String] {
        guard request.question.lowercased().contains("undo") else { return [] }
        return (request.history.last?.createdAnnotationIDs ?? []).map(\.uuidString)
    }

    static func cannedActions(for request: InkyRequest) -> [InkyAction] {
        let q = request.question.lowercased()
        if q.contains("undo") {
            return [.say(SayAction(text: "Okay, I took that back."))]
        }
        if q.contains("hydrogen") {
            // A recognized structure: name the atoms, the app places the H's exactly.
            if let structure = request.structures.first {
                let hidden = structure.atoms.reduce(0) { $0 + $1.hiddenHydrogens }
                return [
                    .say(SayAction(text: "Here are the hidden hydrogens — \(hidden) in total.")),
                    .annotateStructure(AnnotateStructureAction(
                        structure: structure.id, relabel: [], hydrogens: ["all"], lonePairs: [], charges: [],
                        highlights: [], labels: [], arrows: [], color: .indigo)),
                ]
            }
            return [.say(SayAction(text: "Here are the hidden hydrogens."))] + [.draw(mockHydrogens(request))]
        }
        if let structure = request.structures.first, q.contains("chiral") || q.contains("stereo") || q.contains("hybridi") || q.contains("all the functional") || q.contains("formula") {
            var insights: [AnnotateStructureAction.Insight] = []
            if q.contains("chiral") || q.contains("stereo") { insights.append(.stereocenters) }
            if q.contains("hybridi") { insights.append(.hybridization) }
            if q.contains("all the functional") { insights += [.functionalGroups, .aromaticRings] }
            if q.contains("formula") { insights.append(.formula) }
            return [
                .say(SayAction(text: "Here's what this structure has.")),
                .annotateStructure(AnnotateStructureAction(structure: structure.id, relabel: [], insights: insights, hydrogens: [], lonePairs: [],
                                                           charges: [], highlights: [], labels: [], arrows: [], color: .indigo)),
            ]
        }
        if q.contains("lone pair"), let structure = request.structures.first {
            return [
                .say(SayAction(text: "Lone pairs added.")),
                .annotateStructure(AnnotateStructureAction(
                    structure: structure.id, relabel: [], hydrogens: [], lonePairs: ["all"], charges: [],
                    highlights: [.init(atoms: [], group: "amide", color: .yellow, note: "amide")], labels: [], arrows: [], color: .indigo)),
            ]
        }
        if q.contains("quadratic") || q.contains("neatly") || q.contains("typeset") {
            let spoken: [InkyAction] = request.narrate ? [.narrate(NarrateAction(text: "Let's factor it: we need two numbers that multiply to six and add to minus five."))] : []
            return spoken + [
                .say(SayAction(text: "Here it is, step by step.")),
                .insertMath(InsertMathAction(
                    near: NormRect(x: 0.1, y: 0.62, width: 0.6, height: 0.25), title: "Solving x² − 5x + 6 = 0",
                    lines: [.init(latex: "x^2 - 5x + 6 = 0", note: nil),
                            .init(latex: "(x - 2)(x - 3) = 0", note: "factor"),
                            .init(latex: "x = 2 \\quad\\text{or}\\quad x = 3", note: "zero product")],
                    align: true, boxLast: true, caption: nil)),
            ]
        }
        if q.contains("practice") || q.contains("quiz") {
            return [
                .say(SayAction(text: "Here are three to try — hints if you need them.")),
                .insertPractice(InsertPracticeAction(near: NormRect(x: 0.55, y: 0.55, width: 0.4, height: 0.3), title: "Practice: factoring", problems: [
                    .init(prompt: "Solve \\(x^2 - 7x + 12 = 0\\).", hints: ["Find two numbers that multiply to 12 and add to −7."],
                          answer: "\\(x = 3\\) or \\(x = 4\\)", solution: ["\\((x-3)(x-4) = 0\\)", "\\(x = 3\\) or \\(x = 4\\)"]),
                    .init(prompt: "Solve \\(x^2 + 2x - 15 = 0\\).", hints: ["Which factors of −15 add to 2?"],
                          answer: "\\(x = 3\\) or \\(x = -5\\)", solution: ["\\((x+5)(x-3) = 0\\)"]),
                    .init(prompt: "Solve \\(2x^2 - 8 = 0\\).", hints: ["Divide by 2 first.", "\\(x^2 = 4\\)"],
                          answer: "\\(x = \\pm 2\\)", solution: ["\\(x^2 = 4\\)", "\\(x = \\pm 2\\)"]),
                ])),
            ]
        }
        if let shape = request.shapes.first(where: { !$0.contacts.isEmpty }), q.contains("free-body") || q.contains("forces") {
            return [
                .say(SayAction(text: "Here are the forces on the block.")),
                .annotateShape(AnnotateShapeAction(shape: shape.id, vectors: [
                    .init(label: "mg", direction: .down, angle: nil, from: "center", length: .long, color: .red),
                    .init(label: "N", direction: .normal, angle: nil, from: "center", length: .medium, color: .blue),
                ], angleMarks: [], sideLabels: [], ticks: [], color: .indigo)),
            ] + request.shapes.filter { $0.kind == .triangle }.prefix(1).map { tri in
                .annotateShape(AnnotateShapeAction(shape: tri.id, vectors: [],
                                                   angleMarks: tri.angles.indices.map { .init(vertex: "v\($0 + 1)", label: "\(Int(tri.angles[$0].rounded()))°", right: abs(tri.angles[$0] - 90) < 3) },
                                                   sideLabels: [], ticks: [], color: .indigo))
            }
        }
        if q.contains("resonance") {
            return [
                .say(SayAction(text: "Here are the resonance structures of phenoxide.")),
                .insertChemScheme(InsertChemSchemeAction(
                    near: NormRect(x: 0.08, y: 0.62, width: 0.84, height: 0.22), title: "Phenoxide resonance",
                    steps: [.init(smiles: "[O-:1][C:2]1=CC=CC=C1", label: nil), .init(smiles: "[O:1]=[C:2]1[CH-:3]C=CC=C1", label: nil),
                            .init(smiles: "[O:1]=[C:2]1C=C[CH-:4]C=C1", label: nil)],
                    connectors: [.init(kind: .resonance, above: nil, below: nil), .init(kind: .resonance, above: nil, below: nil)],
                    arrows: [.init(step: 0, from: "1", to: "1-2", kind: .curved)], lonePairs: [.init(step: 0, atom: "1")],
                    highlights: [], caption: "The negative charge spreads to the ortho and para carbons.")),
            ]
        }
        if q.contains("diagram") || q.contains(" cell") {
            let svg = """
            <svg viewBox="0 0 320 220"><ellipse cx="160" cy="110" rx="140" ry="95" class="fill-green green"/>
            <circle cx="140" cy="110" r="38" class="fill-accent accent"/>
            <path d="M215 60 Q240 50 250 70 Q255 85 235 90 Q210 92 215 60 Z" class="fill-orange orange"/></svg>
            """
            return [
                .say(SayAction(text: "Here's a simple animal cell.")),
                .insertDiagram(InsertDiagramAction(near: NormRect(x: 0.1, y: 0.6, width: 0.6, height: 0.3), title: "Animal cell", svg: svg,
                                                   callouts: [.init(text: "Nucleus", x: 140, y: 110), .init(text: "Mitochondrion", x: 240, y: 72),
                                                              .init(text: "Cell membrane", x: 290, y: 140), .init(text: "Cytoplasm", x: 70, y: 150)],
                                                   caption: nil)),
            ]
        }
        if q.contains("new page") {
            let steps = ["2x + 6 = 14", "2x = 8", "x = 4"]
            return [
                .say(SayAction(text: "Worked it out on a new page.")),
                .addPage(AddPageAction(paper: .grid)),
                .draw(DrawAction(ink: .pen, color: .indigo, shapes: [
                    .init(kind: .text, points: [NormPoint(x: 0.1, y: 0.06)], text: "Solving 2x + 6 = 14", size: .large),
                ] + steps.enumerated().map { i, step in
                    .init(kind: .text, points: [NormPoint(x: 0.12, y: 0.16 + Double(i) * 0.06)], text: step, size: .medium)
                } + [
                    .init(kind: .ellipse, points: [NormPoint(x: 0.1, y: 0.27), NormPoint(x: 0.3, y: 0.33)], text: nil, size: .medium),
                ], caption: "worked solution")),
            ]
        }
        if q.contains("functional group") {
            return [
                .say(SayAction(text: "An amide and a phenol, highlighted on the card.")),
                .insertMoleculeCard(InsertMoleculeCardAction(
                    smiles: "CC(=O)Nc1ccc(O)cc1", near: NormRect(x: 0.55, y: 0.5, width: 0.4, height: 0.28),
                    highlightGroups: ["amide", "phenol"], starGroups: [], caption: "Acetaminophen"
                )),
            ]
        }
        if q.contains("asymptote") {
            return [
                .say(SayAction(text: "Vertical at x = 3, horizontal at y = 2.")),
                .insertGraphCard(InsertGraphCardAction(
                    spec: GraphSpec(
                        title: "f(x) = (2x + 1)/(x − 3)", xMin: -10, xMax: 14, yMin: -10, yMax: 14,
                        functions: [.init(expression: "(a*x + 1)/(x - 3)", label: "f", color: nil)],
                        params: [.init(name: "a", min: 0.5, max: 4, value: 2, step: 0.1)],
                        asymptotes: [
                            .init(orientation: .vertical, value: 3, label: "x = 3"),
                            .init(orientation: .horizontal, value: 2, label: "y = 2"),
                        ],
                        points: [], labels: []
                    ),
                    near: NormRect(x: 0.5, y: 0.45, width: 0.45, height: 0.45)
                )),
            ]
        }
        if q.contains("fill") {
            return [.say(SayAction(text: "Filled in every box."))] + request.blanks.enumerated().map { i, box in
                .fillText(FillTextAction(region: box, text: "\(i + 1)", handwritingStyle: true))
            }
        }
        let target = request.lassoRegion
            ?? request.recognizedText.first?.box.insetBy(dx: -0.005, dy: -0.005)
            ?? NormRect(x: 0.1, y: 0.06, width: 0.6, height: 0.05)

        if q.contains("explain") || q.contains("why") {
            return [
                .openSidebar(OpenSidebarAction(
                    markdown: "# Here's the idea\n\nThis is a **mock explanation** from Inky.\n\n- Point one\n- Point two\n\nAsk again with the real proxy for a real answer.",
                    speakable: true
                )),
                .say(SayAction(text: "I opened an explanation in the sidebar.")),
            ]
        }
        if q.contains("molecule") || q.contains("structure") {
            return [
                .insertMoleculeCard(InsertMoleculeCardAction(
                    smiles: "CC(=O)O", near: NormRect(x: 0.55, y: 0.25, width: 0.35, height: 0.2),
                    highlightGroups: ["C(=O)[OH]"], starGroups: [], caption: "Acetic acid"
                )),
                .say(SayAction(text: "Here's the molecule.")),
            ]
        }
        if q.contains("graph") || q.contains("plot") {
            return [
                .insertGraphCard(InsertGraphCardAction(
                    spec: GraphSpec(
                        title: "y = a·sin(x)", xMin: -6.3, xMax: 6.3, yMin: -3, yMax: 3,
                        functions: [.init(expression: "a*Math.sin(x)", label: "f", color: nil)],
                        params: [.init(name: "a", min: 0, max: 3, value: 1, step: 0.1)],
                        asymptotes: [], points: [], labels: []
                    ),
                    near: NormRect(x: 0.1, y: 0.55, width: 0.45, height: 0.3)
                )),
                .say(SayAction(text: "Here's an interactive graph.")),
            ]
        }
        // Default: exercise every page renderer so UI tests can see the whole layer.
        return [
            .highlight(HighlightAction(region: target, color: .yellow, note: nil)),
            .circle(CircleAction(region: NormRect(x: 0.1, y: 0.3, width: 0.3, height: 0.08), style: .solid)),
            .star(StarAction(point: NormPoint(x: max(0.03, target.minX - 0.03), y: target.center.y))),
            .label(LabelAction(anchor: NormPoint(x: target.maxX, y: target.center.y), text: "Title", arrow: true)),
            .fillText(FillTextAction(region: NormRect(x: 0.5, y: 0.6, width: 0.35, height: 0.05), text: "x = 42", handwritingStyle: true)),
            .say(SayAction(text: "Highlighted the title.")),
        ]
    }
}
