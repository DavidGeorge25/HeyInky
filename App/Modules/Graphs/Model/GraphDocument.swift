import Foundation

/// A graph card's editable state: the persisted `GraphSpec` plus its compiled expressions.
/// Every mutation keeps the spec valid (ordered ranges, params inside their ranges) and
/// re-compiles what changed. Pure value type, so editing logic is unit-testable.
struct GraphDocument: Hashable, Sendable {
    private(set) var spec: GraphSpec
    /// One entry per `spec.functions`, in order.
    private(set) var compiled: [Result<GraphExpr, GraphExpressionError>]

    static let defaultWindow = GraphAnalysis.Window(xMin: -10, xMax: 10, yMin: -10, yMax: 10)

    init(spec: GraphSpec) {
        self.spec = Self.normalized(spec)
        self.compiled = []
        recompile()
    }

    var paramNames: [String] { spec.params.map(\.name) }
    var paramValues: [Double] { spec.params.map(\.value) }

    var window: GraphAnalysis.Window {
        GraphAnalysis.Window(xMin: spec.xMin, xMax: spec.xMax, yMin: spec.yMin, yMax: spec.yMax)
    }

    var axisLabels: (x: String, y: String) { GraphPresets.axisLabels(for: spec) }

    func expression(at index: Int) -> GraphExpr? {
        guard compiled.indices.contains(index), case .success(let e) = compiled[index] else { return nil }
        return e
    }

    func error(at index: Int) -> GraphExpressionError? {
        guard compiled.indices.contains(index), case .failure(let e) = compiled[index] else { return nil }
        return e
    }

    /// Evaluator for function `index` with the current slider values.
    func evaluator(at index: Int) -> ((Double) -> Double)? {
        guard let e = expression(at: index) else { return nil }
        let values = paramValues
        return { x in e.evaluate(x: x, params: values) }
    }

    /// Display name for a function: its label, else f, g, h, …
    func functionName(at index: Int) -> String {
        if let label = spec.functions[index].label, !label.isEmpty { return label }
        let names = ["f", "g", "h", "p", "q", "r"]
        return names[index % names.count] + (index >= names.count ? "\(index / names.count + 1)" : "")
    }

    /// Checks a candidate expression against the current params without changing anything.
    func validate(_ text: String) -> Result<GraphExpr, GraphExpressionError> {
        Result { () throws(GraphExpressionError) in try GraphExpr.parse(text, params: paramNames) }
    }

    // MARK: Editing

    mutating func setExpression(_ text: String, at index: Int) throws(GraphExpressionError) {
        guard spec.functions.indices.contains(index) else { return }
        let parsed = try GraphExpr.parse(text, params: paramNames)
        spec.functions[index].expression = text.trimmingCharacters(in: .whitespacesAndNewlines)
        compiled[index] = .success(parsed)
    }

    @discardableResult
    mutating func addFunction(_ text: String, label: String? = nil) throws(GraphExpressionError) -> Int {
        let parsed = try GraphExpr.parse(text, params: paramNames)
        spec.functions.append(.init(expression: text.trimmingCharacters(in: .whitespacesAndNewlines), label: label, color: nil))
        compiled.append(.success(parsed))
        return spec.functions.count - 1
    }

    mutating func removeFunction(at index: Int) {
        guard spec.functions.indices.contains(index) else { return }
        spec.functions.remove(at: index)
        compiled.remove(at: index)
    }

    mutating func setParamValue(_ value: Double, at index: Int) {
        guard spec.params.indices.contains(index), value.isFinite else { return }
        let p = spec.params[index]
        spec.params[index].value = min(max(value, p.min), p.max)
    }

    mutating func setParamValue(_ value: Double, named name: String) {
        if let i = spec.params.firstIndex(where: { $0.name == name }) { setParamValue(value, at: i) }
    }

    struct RangeError: Error, Hashable, Sendable { var message: String }

    /// Changes a slider's range; the value is clamped into it.
    mutating func setParamRange(at index: Int, min lo: Double, max hi: Double, step: Double?) throws(RangeError) {
        guard spec.params.indices.contains(index) else { return }
        guard lo.isFinite, hi.isFinite else { throw RangeError(message: "Min and max need to be numbers.") }
        guard lo < hi else { throw RangeError(message: "Min has to be less than max.") }
        if let step, !(step > 0 && step.isFinite && step <= hi - lo) {
            throw RangeError(message: "Step has to be positive and fit in the range.")
        }
        spec.params[index].min = lo
        spec.params[index].max = hi
        spec.params[index].step = step
        spec.params[index].value = Swift.min(Swift.max(spec.params[index].value, lo), hi)
    }

    /// Adds a slider (e.g. after the student typed an unknown name like `k`). Re-compiles all
    /// functions, since a new name can fix ones that failed.
    mutating func addParam(named name: String, value: Double = 1) {
        guard GraphExpressionParser.isSliderName(name), !paramNames.contains(name) else { return }
        let magnitude = Swift.max(abs(value) * 2, 5)
        spec.params.append(.init(name: name, min: -magnitude, max: magnitude, value: value, step: Self.niceStep(for: 2 * magnitude)))
        recompile()
    }

    mutating func removeParam(at index: Int) {
        guard spec.params.indices.contains(index) else { return }
        spec.params.remove(at: index)
        recompile()
    }

    mutating func setWindow(_ w: GraphAnalysis.Window) {
        guard w.xMin.isFinite, w.xMax.isFinite, w.yMin.isFinite, w.yMax.isFinite, w.xMin < w.xMax, w.yMin < w.yMax else { return }
        spec.xMin = w.xMin; spec.xMax = w.xMax; spec.yMin = w.yMin; spec.yMax = w.yMax
    }

    mutating func movePoint(at index: Int, x: Double, y: Double) {
        guard spec.points.indices.contains(index), spec.points[index].draggable, x.isFinite, y.isFinite else { return }
        spec.points[index].x = x
        spec.points[index].y = y
    }

    mutating func setTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        spec.title = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Same x range; y range fitted to what the curves do there (robust to poles).
    func fittedWindow() -> GraphAnalysis.Window {
        let w = window
        var ys: [Double] = []
        for i in spec.functions.indices {
            guard let f = evaluator(at: i) else { continue }
            for k in 0...200 { let y = f(w.xMin + w.xSpan * Double(k) / 200); if y.isFinite { ys.append(y) } }
        }
        ys += spec.points.map(\.y)
        guard ys.count >= 2 else { return w }
        ys.sort()
        var lo = ys[Int(Double(ys.count - 1) * 0.02)], hi = ys[Int(Double(ys.count - 1) * 0.98)]
        // Keep the x-axis in view when it's close.
        if lo > 0, lo < (hi - lo) * 0.5 { lo = 0 }
        if hi < 0, -hi < (hi - lo) * 0.5 { hi = 0 }
        if hi - lo < 1e-9 { lo -= 1; hi += 1 }
        let pad = (hi - lo) * 0.1
        return GraphAnalysis.Window(xMin: w.xMin, xMax: w.xMax, yMin: lo - pad, yMax: hi + pad)
    }

    // MARK: Analysis

    /// Model-given asymptotes plus the ones detected on each curve (duplicates dropped).
    func analysis() -> GraphAnalysis.Result {
        let w = window
        var result = GraphAnalysis.Result()
        result.asymptotes = spec.asymptotes.map { a in
            switch a.orientation {
            case .vertical: .vertical(a.value, label: a.label, isAuto: false)
            case .horizontal: .horizontal(a.value, label: a.label, isAuto: false)
            case .oblique: .oblique(slope: a.slope ?? 0, intercept: a.value, label: a.label, isAuto: false)
            }
        }
        for i in spec.functions.indices {
            // Constants (like a Vmax/2 guide) are their own "asymptote"; nothing to find.
            guard let e = expression(at: i), e.usesVariable, let f = evaluator(at: i) else { continue }
            let r = GraphAnalysis.analyze(function: i, window: w, f)
            result.features += r.features
            for line in r.asymptotes where !result.asymptotes.contains(where: { $0.isSameLine(as: line, tolerance: Self.lineTolerance(line, w)) }) {
                // A straight line "approaches" itself; that's not an asymptote.
                if line.kind == .oblique, Self.isLine(f, slope: line.slope, intercept: line.value, window: w) { continue }
                if line.kind == .horizontal, Self.isLine(f, slope: 0, intercept: line.value, window: w) { continue }
                // Horizontal/oblique lines far outside the view would only confuse.
                if line.kind == .horizontal, line.value < w.yMin || line.value > w.yMax { continue }
                result.asymptotes.append(line)
            }
        }
        // A model-given line was right for the parameters Inky chose; once a slider moves the
        // curve's own asymptote (detected above) is the truth. Drop a given line the curve now
        // contradicts: same kind detected elsewhere, nothing detected at the given value.
        // (One curve only: with several, a different curve's line proves nothing.)
        if !spec.params.isEmpty, spec.functions.count == 1 {
            let detected = result.asymptotes.filter(\.isAuto)
            result.asymptotes.removeAll { given in
                guard !given.isAuto else { return false }
                let sameKind = detected.filter { $0.kind == given.kind }
                return !sameKind.isEmpty && !sameKind.contains { $0.isSameLine(as: given, tolerance: Self.lineTolerance(given, w)) }
            }
        }
        return result
    }

    /// Fixed points Inky marked on a curve (roots, intercepts, vertex) stop being true once a
    /// slider moves; the detected features follow the curve instead. With sliders, a fixed point
    /// that no curve passes through any more is hidden. (Draggable points are the student's.)
    func stalePointIndices() -> [Int] {
        guard !spec.params.isEmpty else { return [] }
        let evaluators = spec.functions.indices.compactMap { evaluator(at: $0) }
        guard !evaluators.isEmpty else { return [] }
        let tolerance = (spec.yMax - spec.yMin) * 0.01
        return spec.points.indices.filter { i in
            let p = spec.points[i]
            guard !p.draggable else { return false }
            return !evaluators.contains { f in
                let y = f(p.x)
                return y.isFinite && abs(y - p.y) <= tolerance
            }
        }
    }

    private static func lineTolerance(_ line: GraphAsymptoteLine, _ w: GraphAnalysis.Window) -> Double {
        line.kind == .vertical ? w.xSpan * 1e-3 : w.ySpan * 1e-3
    }

    private static func isLine(_ f: (Double) -> Double, slope m: Double, intercept b: Double, window w: GraphAnalysis.Window) -> Bool {
        (0...20).allSatisfy { k in
            let x = w.xMin + w.xSpan * Double(k) / 20
            let y = f(x)
            return !y.isFinite || abs(y - (m * x + b)) <= w.ySpan * 1e-7
        }
    }

    // MARK: Normalization

    private mutating func recompile() {
        let names = paramNames
        compiled = spec.functions.map { f in
            Result { () throws(GraphExpressionError) in try GraphExpr.parse(f.expression, params: names) }
        }
    }

    static func normalized(_ input: GraphSpec) -> GraphSpec {
        var spec = input
        let d = defaultWindow
        if !(spec.xMin.isFinite && spec.xMax.isFinite && spec.xMin < spec.xMax) { spec.xMin = d.xMin; spec.xMax = d.xMax }
        if !(spec.yMin.isFinite && spec.yMax.isFinite && spec.yMin < spec.yMax) { spec.yMin = d.yMin; spec.yMax = d.yMax }
        var seen = Set<String>()
        spec.params = spec.params.compactMap { p in
            let name = p.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !seen.contains(name), p.value.isFinite || (p.min.isFinite && p.max.isFinite) else { return nil }
            seen.insert(name)
            var q = p
            q.name = name
            if !q.value.isFinite { q.value = (q.min + q.max) / 2 }
            if !q.min.isFinite { q.min = Swift.min(q.value, 0) - 5 }
            if !q.max.isFinite { q.max = Swift.max(q.value, 0) + 5 }
            if q.min > q.max { swap(&q.min, &q.max) }
            if q.min == q.max { q.min -= 1; q.max += 1 }
            // A value outside its range widens the range rather than jumping.
            q.min = Swift.min(q.min, q.value)
            q.max = Swift.max(q.max, q.value)
            if let step = q.step, !(step > 0 && step.isFinite) { q.step = nil }
            return q
        }
        spec.points = spec.points.filter { $0.x.isFinite && $0.y.isFinite }
        spec.labels = spec.labels.filter { $0.x.isFinite && $0.y.isFinite }
        spec.asymptotes = spec.asymptotes.filter { $0.value.isFinite }
        return spec
    }

    /// 1, 2 or 5 × 10ⁿ giving about 100 steps across `span`.
    static func niceStep(for span: Double) -> Double {
        guard span > 0, span.isFinite else { return 0.1 }
        let raw = span / 100
        let magnitude = pow(10, floor(log10(raw)))
        let n = raw / magnitude
        return (n < 1.5 ? 1 : n < 3.5 ? 2 : n < 7.5 ? 5 : 10) * magnitude
    }
}
