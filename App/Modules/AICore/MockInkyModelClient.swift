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
            return [.say(SayAction(text: "Here are the hidden hydrogens."))] + [.draw(mockHydrogens(request))]
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
