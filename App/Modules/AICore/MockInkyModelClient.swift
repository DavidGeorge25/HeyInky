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
        return AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: delay)
                if Task.isCancelled {
                    continuation.finish(throwing: InkyClientError.cancelled)
                    return
                }
                for action in actions { continuation.yield(.action(action)) }
                continuation.yield(.completed(InkyResponse(actions: actions)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func cannedActions(for request: InkyRequest) -> [InkyAction] {
        let q = request.question.lowercased()
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
