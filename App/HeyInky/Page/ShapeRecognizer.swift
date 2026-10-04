import PencilKit
import UIKit

/// Shape auto-correction ("draw and hold", like GoodNotes): a stroke that ends with the pen held
/// still is recognized as a line, circle/ellipse, triangle, rectangle or polygon and redrawn
/// clean in the same ink. Pure geometry, so it's unit-testable.
enum ShapeRecognizer {
    enum Shape: Equatable {
        case line(CGPoint, CGPoint)
        case ellipse(CGRect)
        /// Closed polygon (triangle, rectangle, …), corners in drawing order.
        case polygon([CGPoint])
        /// Open polyline with a few straight segments (an angle, a zig-zag).
        case polyline([CGPoint])

        var name: String {
            switch self {
            case .line: "line"
            case .ellipse(let r): abs(r.width - r.height) < 0.08 * max(r.width, r.height) ? "circle" : "ellipse"
            case .polygon(let p): p.count == 3 ? "triangle" : p.count == 4 ? "rectangle" : "polygon"
            case .polyline: "polyline"
            }
        }
    }

    /// How long the pen must rest at the end of a stroke, and how still.
    static let holdDuration: TimeInterval = 0.4
    static let holdRadius: CGFloat = 5

    /// Whether the stroke ends with the pen held still (the "snap me" gesture).
    static func endsWithHold(_ stroke: PKStroke) -> Bool {
        let path = stroke.path
        guard path.count > 3, let last = path.last else { return false }
        var i = path.count - 1
        while i > 0 {
            let p = path[i - 1]
            if hypot(p.location.x - last.location.x, p.location.y - last.location.y) > holdRadius { break }
            i -= 1
        }
        return last.timeOffset - path[i].timeOffset >= holdDuration
    }

    /// The shape a hand-drawn stroke most likely is (points in drawing order), or nil.
    static func recognize(_ raw: [CGPoint]) -> Shape? {
        let points = dedupe(raw)
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal > 12 else { return nil }
        let length = DrawInk.polylineLength(points)
        let closed = hypot(last.x - first.x, last.y - first.y) < max(0.18 * diagonal, 14) && length > 2.2 * diagonal * 0.6

        if !closed {
            // Straight line: nothing strays far from the first–last chord.
            let chord = hypot(last.x - first.x, last.y - first.y)
            let deviation = points.map { distance($0, toSegment: first, last) }.max() ?? 0
            if chord > 12, deviation < max(4, 0.07 * chord) {
                let (a, b) = snapAngle(first, last)
                return .line(a, b)
            }
            let corners = InkSkeleton.simplify(points, tolerance: max(5, 0.07 * diagonal))
            if (3...5).contains(corners.count) {
                return .polyline(corners)
            }
            return nil
        }

        // Closed: a polygon if a few corners explain it well, otherwise an ellipse if it's round.
        let loop = points + [first]
        let corners = Array(InkSkeleton.simplify(loop, tolerance: max(6, 0.09 * diagonal)).dropLast())
        let polygonFit = corners.count >= 3 ? meanDistance(points, toPolygon: corners) : .infinity
        let ellipse = bounds
        let ellipseFit = meanEllipseError(points, in: ellipse)

        if (3...6).contains(corners.count), polygonFit < 0.035 * diagonal, polygonFit < ellipseFit * 0.8 {
            return .polygon(regularize(corners))
        }
        if ellipseFit < 0.06 * diagonal {
            // Nearly round → a true circle.
            if abs(ellipse.width - ellipse.height) < 0.12 * max(ellipse.width, ellipse.height) {
                let side = (ellipse.width + ellipse.height) / 2
                return .ellipse(CGRect(x: ellipse.midX - side / 2, y: ellipse.midY - side / 2, width: side, height: side))
            }
            return .ellipse(ellipse)
        }
        if (3...6).contains(corners.count), polygonFit < 0.06 * diagonal {
            return .polygon(regularize(corners))
        }
        return nil
    }

    /// The clean shape as a stroke in `ink`, `width` points wide.
    static func stroke(for shape: Shape, ink: PKInk, width: CGFloat, transform: CGAffineTransform = .identity) -> PKStroke {
        let path: [CGPoint]
        switch shape {
        case .line(let a, let b): path = DrawInk.densify([a, b], spacing: 2)
        case .polyline(let p): path = DrawInk.densify(p, spacing: 2)
        case .polygon(let p): path = DrawInk.densify(p + [p[0]], spacing: 2)
        case .ellipse(let r):
            path = (0...120).map { i in
                let t = CGFloat(i) / 120 * 2 * .pi - .pi / 2
                return CGPoint(x: r.midX + r.width / 2 * cos(t), y: r.midY + r.height / 2 * sin(t))
            }
        }
        let points = path.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let created = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down) + cleanMarker)
        var stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: created))
        stroke.transform = transform
        return stroke
    }

    /// Strokes this recognizer made carry a marker in their timing (exactly 10 ms apart, no
    /// rest), so they aren't corrected twice.
    static func isClean(_ stroke: PKStroke) -> Bool {
        let path = stroke.path
        guard path.count > 2 else { return false }
        return (1..<min(path.count, 6)).allSatisfy { abs(path[$0].timeOffset - path[$0 - 1].timeOffset - 0.01) < 0.0001 }
            && path.map(\.force).allSatisfy { $0 == 1 } && path.creationDate.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) == cleanMarker
    }

    /// Fractional second of a clean stroke's creation date (a harmless tag).
    static let cleanMarker: TimeInterval = 0.25

    /// The stroke redrawn as the shape it is, or nil if it isn't one.
    static func corrected(_ stroke: PKStroke) -> PKStroke? {
        let raw = stroke.path.interpolatedPoints(by: .distance(2)).map(\.location)
        guard let shape = recognize(raw) else { return nil }
        let sizes = stroke.path.map(\.size.width).sorted()
        let width = sizes.isEmpty ? 3 : sizes[sizes.count / 2]
        return self.stroke(for: shape, ink: stroke.ink, width: width, transform: stroke.transform)
    }

    // MARK: Geometry

    /// Lines within 6° of horizontal, vertical or 45° are snapped (keeping the length).
    static func snapAngle(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let step = CGFloat.pi / 4
        let snapped = (angle / step).rounded() * step
        guard abs(snapped - angle) < 6 * .pi / 180 else { return (a, b) }
        let length = hypot(b.x - a.x, b.y - a.y)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let d = CGPoint(x: cos(snapped) * length / 2, y: sin(snapped) * length / 2)
        return (CGPoint(x: mid.x - d.x, y: mid.y - d.y), CGPoint(x: mid.x + d.x, y: mid.y + d.y))
    }

    /// Near-axis-aligned rectangles become exact rectangles.
    static func regularize(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return corners }
        let angles = (0..<4).map { i -> CGFloat in
            let a = corners[i], b = corners[(i + 1) % 4]
            return atan2(b.y - a.y, b.x - a.x)
        }
        let axisAligned = angles.allSatisfy { a in
            let r = abs(a.truncatingRemainder(dividingBy: .pi / 2))
            return min(r, .pi / 2 - r) < 10 * .pi / 180
        }
        guard axisAligned else { return corners }
        let xs = corners.map(\.x).sorted(), ys = corners.map(\.y).sorted()
        let left = (xs[0] + xs[1]) / 2, right = (xs[2] + xs[3]) / 2
        let top = (ys[0] + ys[1]) / 2, bottom = (ys[2] + ys[3]) / 2
        return [CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)]
    }

    private static func dedupe(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for p in points where result.last.map({ hypot($0.x - p.x, $0.y - p.y) > 0.5 }) ?? true { result.append(p) }
        return result
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let len2 = d.x * d.x + d.y * d.y
        guard len2 > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / len2))
        return hypot(p.x - (a.x + t * d.x), p.y - (a.y + t * d.y))
    }

    private static func meanDistance(_ points: [CGPoint], toPolygon corners: [CGPoint]) -> CGFloat {
        let edges = (0..<corners.count).map { (corners[$0], corners[($0 + 1) % corners.count]) }
        let total = points.reduce(0) { sum, p in sum + (edges.map { distance(p, toSegment: $0.0, $0.1) }.min() ?? 0) }
        return total / CGFloat(max(points.count, 1))
    }

    /// Mean distance (points) of the samples from the ellipse inscribed in `rect`.
    private static func meanEllipseError(_ points: [CGPoint], in rect: CGRect) -> CGFloat {
        let rx = max(rect.width / 2, 0.5), ry = max(rect.height / 2, 0.5)
        let total = points.reduce(0) { sum, p in
            let dx = (p.x - rect.midX) / rx, dy = (p.y - rect.midY) / ry
            let r = hypot(dx, dy)
            return sum + abs(r - 1) * min(rx, ry)
        }
        return total / CGFloat(max(points.count, 1))
    }
}
