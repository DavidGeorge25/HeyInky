import Foundation
import Testing
@testable import HeyInky

@Suite("Graph analysis: asymptotes, intercepts, extrema, inflections")
struct GraphAnalysisTests {
    func analyze(_ source: String, x: ClosedRange<Double> = -10...10, y: ClosedRange<Double> = -10...10,
                 params: [String: Double] = [:]) throws -> GraphAnalysis.Result {
        let names = Array(params.keys).sorted()
        let e = try GraphExpr.parse(source, params: names)
        let values = names.map { params[$0]! }
        let w = GraphAnalysis.Window(xMin: x.lowerBound, xMax: x.upperBound, yMin: y.lowerBound, yMax: y.upperBound)
        return GraphAnalysis.analyze(function: 0, window: w) { e.evaluate(x: $0, params: values) }
    }

    func values(_ r: GraphAnalysis.Result, _ kind: GraphAsymptoteLine.Kind) -> [Double] {
        r.asymptotes.filter { $0.kind == kind }.map(\.value).sorted()
    }

    func features(_ r: GraphAnalysis.Result, _ kind: GraphFeature.Kind) -> [GraphFeature] {
        r.features.filter { $0.kind == kind }.sorted { $0.x < $1.x }
    }

    func close(_ a: [Double], _ b: [Double], tolerance: Double = 1e-6) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    // MARK: Vertical

    @Test func reciprocal() throws {
        let r = try analyze("1/x")
        #expect(values(r, .vertical) == [0])
        #expect(values(r, .horizontal) == [0])
        #expect(r.asymptotes.first { $0.kind == .vertical }?.label == "x = 0")
        #expect(features(r, .xIntercept).isEmpty)
        #expect(features(r, .yIntercept).isEmpty, "no y-intercept at a pole")
        #expect(features(r, .maximum).isEmpty && features(r, .minimum).isEmpty)
    }

    @Test func rationalWithTwoPolesAndHorizontalAsymptote() throws {
        let r = try analyze("(2*x^2 + 1)/(x^2 - 1)")
        #expect(values(r, .vertical) == [-1, 1])
        #expect(values(r, .horizontal) == [2])
        #expect(r.asymptotes.contains { $0.label == "y = 2" })
        // Local max at x = 0 between the poles: y = -1.
        #expect(features(r, .maximum).map(\.x) == [0])
        #expect(features(r, .maximum).first?.y == -1)
    }

    @Test func poleBetweenSamplesIsFound() throws {
        // 0.123 is never a sample point of the 600-step grid.
        let r = try analyze("1/(x - 0.123)")
        #expect(close(values(r, .vertical), [0.123]))
    }

    @Test func evenPole() throws {
        let r = try analyze("1/(x-2)^2", y: -1...10)
        #expect(values(r, .vertical) == [2])
        #expect(values(r, .horizontal) == [0])
    }

    @Test func tangentPoles() throws {
        let r = try analyze("Math.tan(x)", x: -5...5)
        #expect(close(values(r, .vertical), [-3 * .pi / 2, -.pi / 2, .pi / 2, 3 * .pi / 2], tolerance: 1e-6))
        #expect(close(features(r, .xIntercept).map(\.x), [-.pi, 0, .pi], tolerance: 1e-6))
        #expect(close(features(r, .inflection).map(\.x), [-.pi, 0, .pi], tolerance: 1e-4))
    }

    @Test func logarithmDomainEdge() throws {
        let r = try analyze("Math.log(x)", x: -2...10)
        #expect(values(r, .vertical) == [0])
        #expect(values(r, .horizontal).isEmpty)
        #expect(close(features(r, .xIntercept).map(\.x), [1]))
    }

    @Test func notAsymptotes() throws {
        for source in ["Math.sqrt(x)", "x/x", "Math.floor(x)", "Math.atan(1000*x)", "Math.sin(x)", "x^2", "Math.abs(x)", "x^(1/3)"] {
            let r = try analyze(source)
            #expect(values(r, .vertical).isEmpty, "\(source) has no vertical asymptote")
        }
    }

    // MARK: Horizontal and oblique

    @Test func exponentialHasLeftHorizontalAsymptoteOnly() throws {
        let r = try analyze("Math.exp(x)", y: -2...10)
        #expect(values(r, .horizontal) == [0])
        #expect(values(r, .oblique).isEmpty)
    }

    @Test func logisticLevelsOffAtCarryingCapacity() throws {
        let r = try analyze("K/(1+((K-N0)/N0)*Math.exp(-r*x))", x: -2...30, y: -10...130, params: ["K": 100, "N0": 5, "r": 0.5])
        #expect(values(r, .horizontal) == [0, 100])
        // Inflection at N = K/2, t = ln((K-N0)/N0)/r.
        let inflection = try #require(features(r, .inflection).first)
        #expect(abs(inflection.x - log(19) / 0.5) < 1e-3)
        #expect(abs(inflection.y - 50) < 1e-3)
    }

    @Test func obliqueAsymptote() throws {
        let r = try analyze("(x^2 + 1)/x")
        #expect(values(r, .vertical) == [0])
        let oblique = try #require(r.asymptotes.first { $0.kind == .oblique })
        #expect(oblique.slope == 1 && oblique.value == 0)
        #expect(oblique.label == "y = x")
        #expect(values(r, .horizontal).isEmpty)
    }

    @Test func obliqueWithIntercept() throws {
        let r = try analyze("(x^2 - 1)/(x - 2)")
        #expect(values(r, .vertical) == [2])
        let oblique = try #require(r.asymptotes.first { $0.kind == .oblique })
        #expect(oblique.slope == 1 && oblique.value == 2)
        #expect(oblique.label == "y = x + 2")
    }

    @Test func noFalseHorizontalOrOblique() throws {
        for source in ["Math.sin(x)", "x^2", "Math.log(x)", "Math.sqrt(x)", "x + Math.sin(x)", "x*Math.log(x)"] {
            let r = try analyze(source)
            #expect(values(r, .horizontal).isEmpty, "\(source) has no horizontal asymptote")
            #expect(values(r, .oblique).isEmpty, "\(source) has no oblique asymptote")
        }
        #expect(values(try analyze("Math.sin(x)/x"), .horizontal) == [0])
    }

    // MARK: Intercepts, extrema, inflection

    @Test func cubicKeyPoints() throws {
        let r = try analyze("x^3 - 3*x")
        #expect(close(features(r, .xIntercept).map(\.x), [-3.0.squareRoot(), 0, 3.0.squareRoot()]))
        #expect(features(r, .yIntercept).map(\.y) == [0])
        #expect(features(r, .maximum).map(\.x) == [-1])
        #expect(features(r, .maximum).map(\.y) == [2])
        #expect(features(r, .minimum).map(\.x) == [1])
        #expect(features(r, .minimum).map(\.y) == [-2])
        #expect(close(features(r, .inflection).map(\.x), [0], tolerance: 1e-5))
    }

    @Test func touchingRoot() throws {
        let r = try analyze("(x-1)^2")
        #expect(features(r, .xIntercept).map(\.x) == [1])
        #expect(features(r, .minimum).map(\.x) == [1])
        #expect(features(r, .yIntercept).map(\.y) == [1])
        #expect(features(r, .inflection).isEmpty)
    }

    @Test func straightLineHasNoTurningPoints() throws {
        let r = try analyze("0.5*x + 1")
        #expect(features(r, .xIntercept).map(\.x) == [-2])
        #expect(features(r, .maximum).isEmpty && features(r, .minimum).isEmpty && features(r, .inflection).isEmpty)
    }

    @Test func plateauIsNotATurningPoint() throws {
        let r = try analyze("x < 0 ? 0 : x", y: -1...10)
        #expect(features(r, .maximum).isEmpty && features(r, .minimum).isEmpty)
    }

    @Test func stepIsNotARoot() throws {
        let r = try analyze("x < 0.5 ? -1 : 1")
        #expect(features(r, .xIntercept).isEmpty)
    }

    @Test func onlyVisibleFeatures() throws {
        // Max of -x²+50 is at y = 50, outside the view.
        let r = try analyze("-x^2 + 50")
        #expect(features(r, .maximum).isEmpty)
    }

    @Test func snapping() {
        #expect(GraphAnalysis.snap(1.9999999999, tolerance: 1e-6) == 2)
        #expect(GraphAnalysis.snap(0.12300000001, tolerance: 1e-6) == 0.123)
        #expect(GraphAnalysis.snap(1e-12, tolerance: 1e-9) == 0)
        #expect(GraphAnalysis.snap(.pi, tolerance: 1e-12) == .pi)
    }

    // MARK: Document combines model asymptotes and detected ones

    @Test func documentMergesModelAndAutoAsymptotes() {
        let spec = GraphSpec(
            title: nil, xMin: -5, xMax: 5, yMin: -5, yMax: 5,
            functions: [.init(expression: "1/(x-1) + 2", label: nil, color: nil)], params: [],
            asymptotes: [.init(orientation: .vertical, value: 1, label: "pole")], points: [], labels: []
        )
        let r = GraphDocument(spec: spec).analysis()
        let vertical = r.asymptotes.filter { $0.kind == .vertical }
        #expect(vertical.count == 1, "auto x = 1 is dropped in favor of the model's line")
        #expect(vertical.first?.label == "pole")
        #expect(vertical.first?.isAuto == false)
        #expect(r.asymptotes.contains { $0.kind == .horizontal && $0.value == 2 && $0.isAuto })
    }

    @Test func linesAndConstantsAreNotTheirOwnAsymptotes() {
        let spec = GraphSpec(
            title: nil, xMin: -5, xMax: 5, yMin: -5, yMax: 5,
            functions: [.init(expression: "2*x + 1", label: nil, color: nil), .init(expression: "3", label: nil, color: nil)],
            params: [], asymptotes: [], points: [], labels: []
        )
        let r = GraphDocument(spec: spec).analysis()
        #expect(r.asymptotes.isEmpty)
    }
}
