import Foundation

/// A notable point on a curve, found numerically.
struct GraphFeature: Hashable, Sendable, Encodable {
    enum Kind: String, Hashable, Sendable, Encodable, CaseIterable {
        case xIntercept, yIntercept, maximum, minimum, inflection
    }

    var kind: Kind
    var x: Double
    var y: Double
    /// Index of the function it belongs to.
    var function: Int

    var label: String {
        let coords = "(\(GraphFormat.number(x)), \(GraphFormat.number(y)))"
        return switch kind {
        case .xIntercept, .yIntercept: coords
        case .maximum: "max \(coords)"
        case .minimum: "min \(coords)"
        case .inflection: "infl. \(coords)"
        }
    }
}

/// A dashed guide line: given by the model or detected.
struct GraphAsymptoteLine: Hashable, Sendable, Encodable {
    enum Kind: String, Hashable, Sendable, Encodable {
        case vertical, horizontal, oblique
    }

    var kind: Kind
    /// x for vertical, y for horizontal, y-intercept for oblique.
    var value: Double
    /// Slope for oblique lines (0 otherwise).
    var slope: Double = 0
    var label: String
    var isAuto: Bool
    var function: Int?

    static func vertical(_ x: Double, label: String? = nil, isAuto: Bool, function: Int? = nil) -> Self {
        Self(kind: .vertical, value: x, label: label ?? "x = \(GraphFormat.number(x))", isAuto: isAuto, function: function)
    }

    static func horizontal(_ y: Double, label: String? = nil, isAuto: Bool, function: Int? = nil) -> Self {
        Self(kind: .horizontal, value: y, label: label ?? "y = \(GraphFormat.number(y))", isAuto: isAuto, function: function)
    }

    static func oblique(slope m: Double, intercept b: Double, label: String? = nil, isAuto: Bool, function: Int? = nil) -> Self {
        Self(kind: .oblique, value: b, slope: m, label: label ?? "y = \(GraphFormat.linear(slope: m, intercept: b))", isAuto: isAuto, function: function)
    }

    /// Whether two lines are the same guide (used to skip auto lines the model already gave).
    func isSameLine(as other: Self, tolerance: Double) -> Bool {
        kind == other.kind && abs(value - other.value) <= tolerance && abs(slope - other.slope) <= 1e-6 * max(1, abs(slope))
    }
}

/// Numerical curve analysis over the visible window. Pure functions of `f`, so they're unit-testable.
enum GraphAnalysis {
    struct Window: Hashable, Sendable {
        var xMin: Double, xMax: Double, yMin: Double, yMax: Double
        var xSpan: Double { xMax - xMin }
        var ySpan: Double { max(yMax - yMin, .leastNonzeroMagnitude) }
    }

    struct Result: Hashable, Sendable {
        var features: [GraphFeature] = []
        var asymptotes: [GraphAsymptoteLine] = []
    }

    static let sampleCount = 600
    static let maxFeaturesPerKind = 16

    static func analyze(function index: Int, window w: Window, _ f: (Double) -> Double) -> Result {
        guard w.xSpan > 0, w.xSpan.isFinite, w.ySpan.isFinite else { return Result() }
        let n = sampleCount
        let xs = (0...n).map { w.xMin + w.xSpan * Double($0) / Double(n) }
        let ys = xs.map(f)
        var result = Result()

        let poles = verticalAsymptotes(xs: xs, ys: ys, window: w, f)
        result.asymptotes += poles.map { .vertical($0, isAuto: true, function: index) }
        for side in [1.0, -1.0] {
            if let h = horizontalAsymptote(side: side, scale: w.ySpan, f) {
                if !result.asymptotes.contains(where: { $0.kind == .horizontal && abs($0.value - h) <= w.ySpan * 1e-6 }) {
                    result.asymptotes.append(.horizontal(h, isAuto: true, function: index))
                }
            } else if let o = obliqueAsymptote(side: side, scale: w.ySpan, f) {
                let line = GraphAsymptoteLine.oblique(slope: o.slope, intercept: o.intercept, isAuto: true, function: index)
                if !result.asymptotes.contains(where: { $0.isSameLine(as: line, tolerance: w.ySpan * 1e-6) }) {
                    result.asymptotes.append(line)
                }
            }
        }

        let nearPole = { (a: Double, b: Double) in poles.contains { $0 >= a - w.xSpan * 1e-9 && $0 <= b + w.xSpan * 1e-9 } }
        var features: [GraphFeature] = []
        if w.xMin <= 0, 0 <= w.xMax, !nearPole(0, 0) {
            let y0 = f(0)
            if y0.isFinite { features.append(GraphFeature(kind: .yIntercept, x: 0, y: snap(y0, tolerance: w.ySpan * 1e-9), function: index)) }
        }
        features += roots(xs: xs, ys: ys, window: w, excluding: nearPole, f).map {
            GraphFeature(kind: .xIntercept, x: $0, y: 0, function: index)
        }
        features += extrema(xs: xs, ys: ys, window: w, excluding: nearPole, f).map {
            GraphFeature(kind: $0.isMax ? .maximum : .minimum, x: $0.x, y: $0.y, function: index)
        }
        features += inflections(xs: xs, ys: ys, window: w, excluding: nearPole, f).map {
            GraphFeature(kind: .inflection, x: $0.x, y: $0.y, function: index)
        }
        // Only what's visible, and not so many that the card turns into confetti.
        let margin = w.ySpan * 1e-3
        features = features.filter { $0.y >= w.yMin - margin && $0.y <= w.yMax + margin }
        result.features = GraphFeature.Kind.allCases.flatMap { kind in
            features.filter { $0.kind == kind }.prefix(maxFeaturesPerKind)
        }
        return result
    }

    // MARK: Vertical asymptotes

    /// x positions where |f| grows without bound (poles, and log-like domain edges such as ln x at 0).
    static func verticalAsymptotes(xs: [Double], ys: [Double], window w: Window, _ f: (Double) -> Double) -> [Double] {
        var candidates: [Double] = []
        for i in xs.indices {
            let y = ys[i]
            if !y.isFinite {
                if y.isInfinite { candidates.append(xs[i]) }
                // Edge between a finite and a non-finite sample: bisect to the domain boundary.
                if i > 0, ys[i - 1].isFinite { candidates.append(boundary(finite: xs[i - 1], nonFinite: xs[i], f)) }
                if i + 1 < xs.count, ys[i + 1].isFinite { candidates.append(boundary(finite: xs[i + 1], nonFinite: xs[i], f)) }
                continue
            }
            // Local maxima of |f| bracket poles that fall between samples.
            let left = i > 0 ? abs(ys[i - 1]) : -1, right = i + 1 < ys.count ? abs(ys[i + 1]) : -1
            guard i > 0, i + 1 < xs.count, left.isFinite, right.isFinite, abs(y) >= left, abs(y) >= right, abs(y) > 0 else { continue }
            candidates.append(goldenSection(xs[i - 1], xs[i + 1], maximize: true) { abs(f($0)) })
        }
        var poles: [Double] = []
        for c in candidates where c >= w.xMin - w.xSpan * 1e-9 && c <= w.xMax + w.xSpan * 1e-9 && isPole(c, span: w.xSpan, f) {
            let x = snap(c, tolerance: w.xSpan * 1e-7)
            if !poles.contains(where: { abs($0 - x) <= w.xSpan * 1e-5 }) { poles.append(x) }
        }
        return poles.sorted()
    }

    /// |f| keeps climbing (without its increments dying out) as we approach x0 from at least one side.
    static func isPole(_ x0: Double, span: Double, _ f: (Double) -> Double) -> Bool {
        let deltas = [1e-3, 1e-5, 1e-7, 1e-9].map { $0 * span }
        return [-1.0, 1.0].contains { side in
            let v = deltas.map { abs(f(x0 + side * $0)) }
            guard v.allSatisfy(\.isFinite), zip(v, v.dropFirst()).allSatisfy({ $0 < $1 }) else {
                // Hitting infinity right next to x0 is a pole too (e.g. 1/(x-2)² sampled at 2 ± tiny).
                return v.prefix(2).allSatisfy(\.isFinite) && v[1] > v[0] && v.dropFirst(2).contains(where: \.isInfinite)
            }
            let d1 = v[1] - v[0], d2 = v[2] - v[1], d3 = v[3] - v[2]
            return d2 >= 0.5 * d1 && d3 >= 0.5 * d2 && v[3] > v[0] * 1.5
        }
    }

    private static func boundary(finite a: Double, nonFinite b: Double, _ f: (Double) -> Double) -> Double {
        var good = a, bad = b
        for _ in 0..<80 {
            let mid = (good + bad) / 2
            if mid == good || mid == bad { break }
            if f(mid).isFinite { good = mid } else { bad = mid }
        }
        return (good + bad) / 2
    }

    // MARK: Horizontal and oblique asymptotes

    /// Limit of f as x → ±∞ (side = ±1), if it settles.
    static func horizontalAsymptote(side: Double, scale: Double, _ f: (Double) -> Double) -> Double? {
        let values = [1e3, 1e4, 1e5, 1e6, 1e7].map { f(side * $0) }
        guard values.allSatisfy(\.isFinite) else { return nil }
        let tolerance = 1e-4 * max(1, scale)
        let diffs = zip(values, values.dropFirst()).map { abs($1 - $0) }
        guard diffs[3] < tolerance, diffs[2] < tolerance * 10 else { return nil }
        return snap(values[4], tolerance: tolerance)
    }

    /// Line y = m·x + b that f approaches as x → ±∞, if any (m ≠ 0).
    static func obliqueAsymptote(side: Double, scale: Double, _ f: (Double) -> Double) -> (slope: Double, intercept: Double)? {
        func slope(_ X: Double) -> Double { (f(side * X) - f(side * X / 2)) / (side * X / 2) }
        let m0 = slope(1e5), m1 = slope(1e6)
        guard m0.isFinite, m1.isFinite, abs(m1) > 1e-6, abs(m1 - m0) < 1e-4 * (1 + abs(m1)) else { return nil }
        let m = snap(m1, tolerance: 1e-6 * max(1, abs(m1)))
        let b0 = f(side * 1e5) - m * side * 1e5, b1 = f(side * 1e6) - m * side * 1e6
        let tolerance = 1e-3 * max(1, scale)
        guard b0.isFinite, b1.isFinite, abs(b1 - b0) < tolerance else { return nil }
        return (m, snap(b1, tolerance: tolerance))
    }

    // MARK: Intercepts, extrema, inflections

    static func roots(xs: [Double], ys: [Double], window w: Window, excluding nearPole: (Double, Double) -> Bool, _ f: (Double) -> Double) -> [Double] {
        var found: [Double] = []
        let accept = { (x: Double) in
            let r = snap(x, tolerance: w.xSpan * 1e-7)
            if !found.contains(where: { abs($0 - r) <= w.xSpan * 1e-5 }) { found.append(r) }
        }
        let zeroTolerance = 1e-9 * w.ySpan
        for i in xs.indices {
            let y = ys[i]
            guard y.isFinite else { continue }
            if y == 0 { accept(xs[i]); continue }
            if i + 1 < xs.count, ys[i + 1].isFinite, ys[i + 1] != 0, (y < 0) != (ys[i + 1] < 0), !nearPole(xs[i], xs[i + 1]) {
                let r = bisect(xs[i], xs[i + 1], f)
                // A jump (step function) also changes sign; only accept a real zero.
                if abs(f(r)) <= 1e-6 * w.ySpan { accept(r) }
                continue
            }
            // Touching roots (x² at 0) don't change sign: look at small local minima of |f|.
            if i > 0, i + 1 < xs.count, ys[i - 1].isFinite, ys[i + 1].isFinite,
               abs(y) <= abs(ys[i - 1]), abs(y) <= abs(ys[i + 1]), abs(y) < 1e-2 * w.ySpan,
               (ys[i - 1] < 0) == (y < 0), (ys[i + 1] < 0) == (y < 0) {
                let m = goldenSection(xs[i - 1], xs[i + 1], maximize: false) { abs(f($0)) }
                if abs(f(m)) <= zeroTolerance { accept(m) }
            }
        }
        return found.sorted()
    }

    static func extrema(xs: [Double], ys: [Double], window w: Window, excluding nearPole: (Double, Double) -> Bool, _ f: (Double) -> Double) -> [(x: Double, y: Double, isMax: Bool)] {
        var found: [(x: Double, y: Double, isMax: Bool)] = []
        let noise = 1e-10 * w.ySpan
        // Walk slope signs, skipping flat runs, so plateaus and rounding noise don't count.
        var lastSign = 0, lastIndex = 0
        for i in 1..<xs.count {
            guard ys[i].isFinite, ys[i - 1].isFinite else { lastSign = 0; continue }
            let d = ys[i] - ys[i - 1]
            guard abs(d) > noise else { continue }
            let sign = d > 0 ? 1 : -1
            if lastSign != 0, sign != lastSign {
                let a = xs[max(lastIndex - 1, 0)], b = xs[i]
                if !nearPole(a, b) {
                    let isMax = lastSign > 0
                    let x = snap(goldenSection(a, b, maximize: isMax, f), tolerance: w.xSpan * 1e-7)
                    let y = f(x)
                    if y.isFinite, x > w.xMin, x < w.xMax, !found.contains(where: { abs($0.x - x) <= w.xSpan * 1e-5 }) {
                        found.append((x, snap(y, tolerance: w.ySpan * 1e-7), isMax))
                    }
                }
            }
            lastSign = sign
            lastIndex = i
        }
        return found
    }

    static func inflections(xs: [Double], ys: [Double], window w: Window, excluding nearPole: (Double, Double) -> Bool, _ f: (Double) -> Double) -> [(x: Double, y: Double)] {
        let h = w.xSpan * 1e-4
        func second(_ x: Double) -> Double { (f(x + h) - 2 * f(x) + f(x - h)) / (h * h) }
        let noise = 1e-9 * w.ySpan
        var found: [(x: Double, y: Double)] = []
        var lastSign = 0, lastIndex = 0
        for i in 1..<(xs.count - 1) {
            guard ys[i - 1].isFinite, ys[i].isFinite, ys[i + 1].isFinite else { lastSign = 0; continue }
            let s = ys[i + 1] - 2 * ys[i] + ys[i - 1]
            guard abs(s) > noise else { continue }
            let sign = s > 0 ? 1 : -1
            if lastSign != 0, sign != lastSign, !nearPole(xs[lastIndex - 1], xs[i + 1]) {
                var a = xs[lastIndex], b = xs[i]
                var fa = second(a)
                for _ in 0..<50 {
                    let mid = (a + b) / 2
                    let fm = second(mid)
                    if (fm < 0) == (fa < 0) { a = mid; fa = fm } else { b = mid }
                }
                let x = snap((a + b) / 2, tolerance: w.xSpan * 1e-6)
                let y = f(x)
                if y.isFinite, x > w.xMin, x < w.xMax { found.append((x, snap(y, tolerance: w.ySpan * 1e-7))) }
            }
            lastSign = sign
            lastIndex = i
        }
        return found
    }

    // MARK: Numerics

    static func bisect(_ a: Double, _ b: Double, _ f: (Double) -> Double) -> Double {
        var lo = a, hi = b
        var flo = f(lo)
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if mid == lo || mid == hi { break }
            let fm = f(mid)
            if fm == 0 { return mid }
            if (fm < 0) == (flo < 0) { lo = mid; flo = fm } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    static func goldenSection(_ a: Double, _ b: Double, maximize: Bool, _ f: (Double) -> Double) -> Double {
        let ratio = (5.0.squareRoot() - 1) / 2
        func g(_ x: Double) -> Double {
            let v = f(x)
            if v.isNaN { return -.infinity }
            return maximize ? v : -v
        }
        var lo = a, hi = b
        var c = hi - ratio * (hi - lo), d = lo + ratio * (hi - lo)
        var gc = g(c), gd = g(d)
        for _ in 0..<90 {
            if gc >= gd { hi = d; d = c; gd = gc; c = hi - ratio * (hi - lo); gc = g(c) }
            else { lo = c; c = d; gc = gd; d = lo + ratio * (hi - lo); gd = g(d) }
            if hi - lo <= max(abs(lo), abs(hi), 1) * 1e-15 { break }
        }
        return (lo + hi) / 2
    }

    /// Rounds to the fewest decimals that stay within `tolerance` (2.0000000001 → 2).
    static func snap(_ v: Double, tolerance: Double) -> Double {
        guard v.isFinite else { return v }
        if abs(v) <= tolerance { return 0 }
        for k in 0...10 {
            let p = pow(10.0, Double(k))
            let r = (v * p).rounded() / p
            if abs(r - v) <= tolerance { return r }
        }
        return v
    }
}

/// Number formatting for labels: 4 significant digits, no trailing zeros, compact exponents.
enum GraphFormat {
    static func number(_ v: Double) -> String {
        guard v.isFinite else { return v.isNaN ? "–" : (v > 0 ? "∞" : "−∞") }
        if abs(v) < 1e-12 { return "0" }
        var s = String(format: "%.4g", v)
        if let e = s.firstIndex(of: "e") {
            var mantissa = String(s[..<e]), exponent = String(s[s.index(after: e)...])
            if mantissa.contains(".") { while mantissa.hasSuffix("0") { mantissa.removeLast() }; if mantissa.hasSuffix(".") { mantissa.removeLast() } }
            exponent = exponent.replacingOccurrences(of: "+", with: "")
            while exponent.hasPrefix("0") || exponent.hasPrefix("-0") { exponent = exponent.hasPrefix("-") ? "-" + exponent.dropFirst(2) : String(exponent.dropFirst()) }
            s = "\(mantissa)e\(exponent)"
        } else if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s.hasPrefix("-") ? "−" + s.dropFirst() : s
    }

    /// "2x + 1", "−x − 3", "0.5x".
    static func linear(slope m: Double, intercept b: Double) -> String {
        let mText = m == 1 ? "" : m == -1 ? "−" : number(m)
        var s = "\(mText)x"
        if abs(b) > 1e-12 { s += b > 0 ? " + \(number(b))" : " − \(number(-b))" }
        return s
    }
}
