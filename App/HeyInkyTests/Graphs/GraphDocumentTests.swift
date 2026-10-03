import SwiftUI
import Testing
@testable import HeyInky

func makeGraphSpec(
    _ expressions: [String], params: [GraphSpec.Param] = [], points: [GraphSpec.Point] = [],
    x: ClosedRange<Double> = -10...10, y: ClosedRange<Double> = -10...10
) -> GraphSpec {
    GraphSpec(
        title: nil, xMin: x.lowerBound, xMax: x.upperBound, yMin: y.lowerBound, yMax: y.upperBound,
        functions: expressions.map { .init(expression: $0, label: nil, color: nil) },
        params: params, asymptotes: [], points: points, labels: []
    )
}

@Suite("Graph document editing")
struct GraphDocumentTests {
    @Test func invalidExpressionIsRejectedAndOldOneKept() {
        var doc = GraphDocument(spec: makeGraphSpec(["x^2"]))
        #expect(throws: GraphExpressionError.self) { try doc.setExpression("fetch(x)", at: 0) }
        #expect(doc.spec.functions[0].expression == "x^2")
        #expect(doc.evaluator(at: 0)?(3) == 9)
    }

    @Test func modelExpressionThatFailsShowsAnErrorButKeepsTheCard() {
        let doc = GraphDocument(spec: makeGraphSpec(["window.alert(1)", "x"]))
        #expect(doc.error(at: 0) != nil)
        #expect(doc.expression(at: 0) == nil)
        #expect(doc.evaluator(at: 1)?(2) == 2)
    }

    @Test func addingASliderFixesUnknownNames() throws {
        var doc = GraphDocument(spec: makeGraphSpec(["k*x"]))
        #expect(doc.error(at: 0)?.unknownIdentifier == "k")
        doc.addParam(named: "k", value: 2)
        #expect(doc.error(at: 0) == nil)
        #expect(doc.evaluator(at: 0)?(3) == 6)
        doc.addParam(named: "sin")
        doc.addParam(named: "x")
        doc.addParam(named: "k")
        #expect(doc.paramNames == ["k"], "reserved and duplicate names are ignored")
    }

    @Test func sliderRangesValidateAndClamp() throws {
        var doc = GraphDocument(spec: makeGraphSpec(["a*x"], params: [.init(name: "a", min: 0, max: 10, value: 8, step: 0.5)]))
        #expect(throws: GraphDocument.RangeError.self) { try doc.setParamRange(at: 0, min: 5, max: 5, step: nil) }
        #expect(throws: GraphDocument.RangeError.self) { try doc.setParamRange(at: 0, min: 0, max: 1, step: 0) }
        #expect(throws: GraphDocument.RangeError.self) { try doc.setParamRange(at: 0, min: 0, max: 1, step: 2) }
        try doc.setParamRange(at: 0, min: -1, max: 2, step: 0.25)
        #expect(doc.spec.params[0].value == 2, "value is clamped into the new range")
        #expect(doc.spec.params[0].step == 0.25)
        doc.setParamValue(99, at: 0)
        #expect(doc.spec.params[0].value == 2)
        doc.setParamValue(-0.5, named: "a")
        #expect(doc.evaluator(at: 0)?(2) == -1)
    }

    @Test func normalizationRepairsModelSpecs() {
        var spec = makeGraphSpec(["a*x"], params: [
            .init(name: "a", min: 5, max: 1, value: 7, step: -1),
            .init(name: "a", min: 0, max: 1, value: 0, step: nil),
            .init(name: " ", min: 0, max: 1, value: 0, step: nil),
        ])
        spec.xMin = 3; spec.xMax = -3
        let doc = GraphDocument(spec: spec)
        #expect(doc.spec.xMin == -10 && doc.spec.xMax == 10)
        #expect(doc.spec.params.count == 1)
        #expect(doc.spec.params[0].min == 1 && doc.spec.params[0].max == 7, "swapped, then widened to include the value")
        #expect(doc.spec.params[0].step == nil)
    }

    @Test func onlyDraggablePointsMove() {
        var doc = GraphDocument(spec: makeGraphSpec(["x"], points: [
            .init(x: 1, y: 1, label: "A", draggable: true), .init(x: 2, y: 2, label: "B", draggable: false),
        ]))
        doc.movePoint(at: 0, x: 3, y: 4)
        doc.movePoint(at: 1, x: 3, y: 4)
        #expect(doc.spec.points[0].x == 3 && doc.spec.points[0].y == 4)
        #expect(doc.spec.points[1].x == 2)
    }

    @Test func fittedWindowFollowsTheCurve() {
        let doc = GraphDocument(spec: makeGraphSpec(["100 + x"], x: 0...10, y: -1...1))
        let w = doc.fittedWindow()
        #expect(w.xMin == 0 && w.xMax == 10)
        #expect(w.yMin < 100 && w.yMax > 110)
    }

    @Test func functionNamesAndRemoval() throws {
        var doc = GraphDocument(spec: makeGraphSpec(["x", "2x"]))
        #expect(doc.functionName(at: 0) == "f" && doc.functionName(at: 1) == "g")
        let i = try doc.addFunction("x^2")
        #expect(i == 2 && doc.functionName(at: 2) == "h")
        doc.removeFunction(at: 0)
        #expect(doc.spec.functions.map(\.expression) == ["2x", "x^2"])
        #expect(doc.evaluator(at: 1)?(3) == 9)
    }

    @Test func colorsAreSanitized() {
        #expect(GraphPalette.color(for: "red", index: 0, dark: false) == "#E5484D")
        #expect(GraphPalette.color(for: "#abc", index: 0, dark: false) == "#AABBCC")
        #expect(GraphPalette.color(for: "#12A594", index: 0, dark: false) == "#12A594")
        #expect(GraphPalette.color(for: "url(javascript:alert(1))", index: 1, dark: false) == GraphPalette.light[1])
        #expect(GraphPalette.color(for: nil, index: 0, dark: true) == GraphPalette.dark[0])
    }
}

@Suite("Graph presets")
struct GraphPresetTests {
    func analysis(_ preset: GraphPreset) -> (GraphDocument, GraphAnalysis.Result) {
        let doc = GraphDocument(spec: preset.spec)
        return (doc, doc.analysis())
    }

    func feature(_ r: GraphAnalysis.Result, _ kind: GraphFeature.Kind, function: Int = 0) -> [GraphFeature] {
        r.features.filter { $0.kind == kind && $0.function == function }.sorted { $0.x < $1.x }
    }

    @Test(arguments: GraphPresets.all)
    func presetCompilesCleanly(_ preset: GraphPreset) {
        let doc = GraphDocument(spec: preset.spec)
        for i in doc.spec.functions.indices { #expect(doc.error(at: i) == nil, "\(preset.id) f\(i)") }
        #expect(doc.spec == preset.spec, "presets are already normalized")
        #expect(GraphPresets.axisLabels(for: preset.spec) == (preset.xAxis, preset.yAxis))
    }

    @Test func modelAxisLabelsWinOverPresetAndDashesDontMatter() {
        var spec = GraphPresets.michaelisMenten.spec
        spec.title = "michaelis-menten"
        #expect(GraphPresets.axisLabels(for: spec) == (GraphPresets.michaelisMenten.xAxis, GraphPresets.michaelisMenten.yAxis))
        spec.xLabel = "[S] (µM)"
        spec.yLabel = " "
        #expect(GraphPresets.axisLabels(for: spec) == ("[S] (µM)", GraphPresets.michaelisMenten.yAxis))
    }

    @Test func modelObliqueAsymptoteIsDrawnOnce() {
        let spec = GraphSpec(
            title: nil, xMin: -6, xMax: 6, yMin: -8, yMax: 8,
            functions: [.init(expression: "(x**2 + 1)/x", label: nil, color: nil)], params: [],
            asymptotes: [.init(orientation: .oblique, value: 0, slope: 1, label: "y = x")], points: [], labels: []
        )
        let r = GraphDocument(spec: spec).analysis()
        let oblique = r.asymptotes.filter { $0.kind == .oblique }
        #expect(oblique.count == 1, "the detected y = x merges with the model's")
        #expect(oblique.first?.label == "y = x")
        #expect(oblique.first?.isAuto == false)
        #expect(r.asymptotes.contains { $0.kind == .vertical && abs($0.value) < 1e-6 })
    }

    @Test func modelAsymptotesFollowTheSliders() {
        let spec = GraphSpec(
            title: nil, xMin: -10, xMax: 14, yMin: -10, yMax: 14,
            functions: [.init(expression: "(a*x + 1)/(x - 3)", label: nil, color: nil)],
            params: [.init(name: "a", min: 0.5, max: 4, value: 2, step: 0.1)],
            asymptotes: [.init(orientation: .vertical, value: 3, label: "x = 3"), .init(orientation: .horizontal, value: 2, label: "y = 2")],
            points: [], labels: []
        )
        var doc = GraphDocument(spec: spec)
        #expect(doc.analysis().asymptotes.filter { $0.kind == .horizontal }.map(\.label) == ["y = 2"], "Inky's label at Inky's values")
        doc.setParamValue(3.8, named: "a")
        let r = doc.analysis()
        #expect(r.asymptotes.filter { $0.kind == .horizontal }.map(\.value) == [3.8], "the stale y = 2 is gone")
        #expect(r.asymptotes.contains { $0.kind == .vertical && $0.label == "x = 3" }, "still-true lines keep Inky's label")
    }

    @Test func inkysPointsHideWhenASliderMovesThemOffTheCurve() {
        var spec = GraphSpec(
            title: nil, xMin: -10, xMax: 14, yMin: -10, yMax: 14,
            functions: [.init(expression: "(a*x + 1)/(x - 3)", label: nil, color: nil)],
            params: [.init(name: "a", min: 0.5, max: 5, value: 2, step: 0.1)],
            asymptotes: [], points: [], labels: []
        )
        spec.points = [
            .init(x: -0.5, y: 0, label: "x-int", draggable: false),
            .init(x: 0, y: -1.0 / 3, label: "y-int", draggable: false),
            .init(x: 5, y: 5, label: "drag me", draggable: true),
        ]
        var doc = GraphDocument(spec: spec)
        #expect(doc.stalePointIndices().isEmpty, "all true at Inky's values")
        doc.setParamValue(4.8, named: "a")
        #expect(doc.stalePointIndices() == [0], "the x-intercept moved; the y-intercept didn't; draggable points stay")
        #expect(GraphScene(document: doc, theme: .light).patch.hiddenPoints == [0])
    }

    @Test func michaelisMentenSaturatesAtVmax() {
        let (_, r) = analysis(GraphPresets.michaelisMenten)
        #expect(r.asymptotes.contains { $0.kind == .horizontal && $0.value == 10 })
        #expect(feature(r, .xIntercept).map(\.x) == [0])
        // v = Vmax/2 at [S] = Km.
        var doc = GraphDocument(spec: GraphPresets.michaelisMenten.spec)
        #expect(doc.evaluator(at: 0)?(2) == 5)
        doc.setParamValue(6, named: "Vmax")
        #expect(doc.analysis().asymptotes.contains { $0.kind == .horizontal && $0.value == 6 }, "asymptote follows the Vmax slider")
    }

    @Test func lineweaverBurkInterceptsAreReciprocals() {
        let (_, r) = analysis(GraphPresets.lineweaverBurk)
        #expect(feature(r, .xIntercept).map(\.x) == [-0.5], "−1/Km")
        #expect(feature(r, .yIntercept).map(\.y) == [0.1], "1/Vmax")
        #expect(r.asymptotes.isEmpty)
    }

    @Test func projectileApexAndRange() {
        let (_, r) = analysis(GraphPresets.projectile)
        let apex = feature(r, .maximum).first ?? GraphFeature(kind: .maximum, x: 0, y: 0, function: 0)
        let v0 = 15.0, g = 9.81
        let apexX: Double = v0 * v0 / (2 * g), apexY: Double = v0 * v0 / (4 * g)
        #expect(abs(apex.x - apexX) < 1e-3)
        #expect(abs(apex.y - apexY) < 1e-3)
        let roots = feature(r, .xIntercept).map(\.x)
        #expect(roots.count == 2)
        #expect(abs(roots[1] - v0 * v0 / g) < 1e-3)
    }

    @Test func logisticAndDoseResponseInflectAtHalfMax() {
        let (_, logistic) = analysis(GraphPresets.logisticGrowth)
        #expect(abs((feature(logistic, .inflection).first?.y ?? 0) - 50) < 1e-3)
        #expect(logistic.asymptotes.filter { $0.kind == .horizontal }.map(\.value).sorted() == [0, 100])

        let (_, dose) = analysis(GraphPresets.doseResponse)
        let mid = feature(dose, .inflection).first
        #expect(abs((mid?.x ?? 0) - -6) < 1e-3, "inflection at log EC50")
        #expect(abs((mid?.y ?? 0) - 50) < 1e-3)
        #expect(dose.asymptotes.filter { $0.kind == .horizontal }.map(\.value).sorted() == [0, 100])
    }

    @Test func harmonicMotionTurningPoints() {
        let (_, r) = analysis(GraphPresets.harmonic)
        let rounded = { (xs: [Double]) -> [Double] in xs.map { ($0 * 1000).rounded() / 1000 } }
        let minima: [Double] = rounded(feature(r, .minimum).map(\.x))
        let maxima: [Double] = rounded(feature(r, .maximum).map(\.x))
        #expect(minima == [3.142, 9.425])
        #expect(maxima == [6.283, 12.566], "4π is just inside xMax = 12.6")
        #expect(feature(r, .maximum).first?.y == 2)
        #expect(r.asymptotes.isEmpty)
    }

    @Test func exponentialGrowthStartsAtN0() {
        let (_, r) = analysis(GraphPresets.exponentialGrowth)
        #expect(feature(r, .yIntercept).map(\.y) == [10])
        #expect(r.asymptotes.contains { $0.kind == .horizontal && $0.value == 0 })
    }
}

@MainActor
@Suite("Graph card model")
struct GraphCardModelTests {
    final class Recorder: @unchecked Sendable {
        var updates: [InsertGraphCardAction] = []
        var flattened: [UIImage] = []
    }

    func makeModel(_ spec: GraphSpec = GraphPresets.michaelisMenten.spec) -> (GraphCardModel, Recorder, InsertGraphCardAction) {
        let recorder = Recorder()
        let model = GraphCardModel()
        model.host = GraphCardHost(
            pageSize: CGSize(width: 816, height: 1056),
            update: { recorder.updates.append($0) },
            flatten: { recorder.flattened.append($0) }
        )
        let action = InsertGraphCardAction(spec: spec, near: NormRect(x: 0.1, y: 0.1, width: 0.4, height: 0.3))
        model.load(action)
        return (model, recorder, action)
    }

    @Test func slidersPersistThroughTheHost() {
        let (model, recorder, _) = makeModel()
        model.setParam(0, to: 7)
        model.persistNow()
        #expect(recorder.updates.last?.spec.params[0].value == 7)
        #expect(model.analysis.asymptotes.contains { $0.kind == .horizontal && $0.value == 7 })
        model.persistNow()
        #expect(recorder.updates.count == 1, "no duplicate writes")
    }

    @Test func tapCurveEditAndAddSlider() {
        let (model, recorder, _) = makeModel(makeGraphSpec(["x^2"]))
        model.handle(.tapFunction(0))
        #expect(model.editingFunction == 0)
        #expect(model.draft == "x^2")
        model.draft = "k*x + 1"
        model.draftChanged()
        #expect(model.draftError?.unknownIdentifier == "k")
        #expect(model.spec?.functions[0].expression == "x^2", "invalid drafts don't replace the curve")
        model.addSliderForDraftUnknown()
        #expect(model.draftError == nil)
        #expect(model.spec?.functions[0].expression == "k*x + 1", "valid drafts redraw live")
        model.finishEditing()
        model.persistNow()
        #expect(model.editingFunction == nil)
        #expect(recorder.updates.last?.spec.functions[0].expression == "k*x + 1")
        #expect(recorder.updates.last?.spec.params.map(\.name) == ["k"])
    }

    @Test func abandoningAnInvalidDraftRestoresTheOriginal() {
        let (model, _, _) = makeModel(makeGraphSpec(["x^2"]))
        model.beginEditing(function: 0)
        model.draft = "x^3"
        model.draftChanged()
        model.draft = "x^3 +"
        model.draftChanged()
        model.finishEditing()
        #expect(model.spec?.functions[0].expression == "x^2")
    }

    @Test func boardMessagesUpdateTheSpec() {
        let (model, recorder, _) = makeModel(makeGraphSpec(["x"], points: [.init(x: 1, y: 1, label: "P", draggable: true)]))
        model.handle(.view(GraphAnalysis.Window(xMin: -1, xMax: 1, yMin: -2, yMax: 2), final: false))
        #expect(model.spec?.xMin == -10, "only resting views are kept")
        model.handle(.view(GraphAnalysis.Window(xMin: -1, xMax: 1, yMin: -2, yMax: 2), final: true))
        #expect(model.spec?.xMin == -1 && model.spec?.yMax == 2)
        model.handle(.point(index: 0, x: 0.5, y: 0.25, final: true))
        model.persistNow()
        #expect(recorder.updates.last?.spec.points[0].x == 0.5)
        #expect(recorder.updates.last?.spec.xMin == -1)
    }

    @Test func ownWritesDontReloadButNewActionsDo() {
        let (model, recorder, action) = makeModel(makeGraphSpec(["x"]))
        model.beginEditing(function: 0)
        model.draft = "2x"
        model.draftChanged()
        model.finishEditing()
        model.persistNow()
        guard let written = recorder.updates.last else { Issue.record("nothing persisted"); return }
        model.load(written)
        #expect(model.spec?.functions[0].expression == "2x")
        model.load(action)
        #expect(model.spec?.functions[0].expression == "x")
    }

    @Test func resizeKeepsCornerAndRespectsMinimum() {
        let (model, recorder, _) = makeModel()
        let page = CGSize(width: 816, height: 1056)
        let before = model.cardRect(pageSize: page)
        model.resize(by: CGSize(width: 1.5, height: 1.2), pageSize: page)
        let after = model.cardRect(pageSize: page)
        #expect(after.x == before.x && after.y == before.y)
        #expect(abs(after.width - before.width * 1.5) < 1e-9)
        #expect(recorder.updates.last?.near == model.action?.near)
        model.resize(by: CGSize(width: 0.01, height: 0.01), pageSize: page)
        #expect(model.cardRect(pageSize: page).width * page.width >= InkyAnnotationGeometry.minCardSize.width - 1e-6)
    }

    @Test func flattenRendersTheCardAtItsPageSize() throws {
        let (model, _, _) = makeModel()
        let page = CGSize(width: 816, height: 1056)
        let image = try #require(model.flattenedImage(pageSize: page, pixelScale: 2))
        let rect = model.cardRect(pageSize: page).cgRect(in: page)
        #expect(abs(image.size.width - rect.width) < 1)
        #expect(image.scale == 2)
    }

    @Test func presetsReplaceTheGraph() {
        let (model, _, _) = makeModel(makeGraphSpec(["x"]))
        model.applyPreset(GraphPresets.projectile)
        #expect(model.spec == GraphPresets.projectile.spec)
    }

    @Test func webMessagesParse() {
        #expect(GraphWebMessage(["type": "ready"]) == .ready)
        #expect(GraphWebMessage(["type": "tapFunction", "index": 2]) == .tapFunction(2))
        #expect(GraphWebMessage(["type": "point", "index": 0, "x": 1.5, "y": -2, "final": false]) == .point(index: 0, x: 1.5, y: -2, final: false))
        #expect(GraphWebMessage(["type": "view", "xMin": -1, "xMax": 1, "yMin": -2, "yMax": 2]) == .view(.init(xMin: -1, xMax: 1, yMin: -2, yMax: 2), final: true))
        #expect(GraphWebMessage(["type": "nope"]) == nil)
        #expect(GraphWebMessage("garbage") == nil)
    }
}
