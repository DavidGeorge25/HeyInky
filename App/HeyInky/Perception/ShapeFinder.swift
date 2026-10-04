import CoreGraphics
import Foundation

/// Closed shapes in line art — the block and ramp of a physics problem, a triangle in geometry
/// homework, a circle — found as the faces of the line drawing's planar graph (polygons) or as
/// round closed strokes (circles). Coordinates are bitmap pixels.
enum ShapeFinder {
    struct Shape: Sendable, Equatable {
        enum Kind: String, Sendable { case triangle, rectangle, square, quadrilateral, polygon, circle }
        var kind: Kind
        /// Counter-clockwise on screen? No: in drawing order, consistent winding (clockwise on screen).
        var vertices: [CGPoint]
        /// For circles: center and radius.
        var center: CGPoint
        var radius: CGFloat
    }

    /// - Parameters:
    ///   - minSize: smallest shape (bounding-box side, pixels) kept, so letters don't count.
    static func shapes(in art: LineArt, minSize: CGFloat) -> [Shape] {
        let sw = art.strokeWidth
        var result: [Shape] = []

        // Circles: closed round strokes.
        for line in art.polylines where line.count >= 8 {
            guard Geometry2D.distance(line[0], line[line.count - 1]) < max(4, 2.5 * sw) else { continue }
            let cx = line.map(\.x).reduce(0, +) / CGFloat(line.count), cy = line.map(\.y).reduce(0, +) / CGFloat(line.count)
            let radii = line.map { hypot($0.x - cx, $0.y - cy) }
            let mean = radii.reduce(0, +) / CGFloat(radii.count)
            let spread = (radii.max() ?? 0) - (radii.min() ?? 0)
            if mean * 2 >= minSize, spread < mean * 0.25 {
                result.append(Shape(kind: .circle, vertices: [], center: CGPoint(x: cx, y: cy), radius: mean))
            }
        }

        // Polygons: faces of the straight-segment graph.
        let tol = max(6, 3 * sw)
        var nodes: [CGPoint] = []
        func node(_ p: CGPoint) -> Int {
            if let i = nodes.firstIndex(where: { Geometry2D.distance($0, p) < tol }) { return i }
            nodes.append(p)
            return nodes.count - 1
        }
        var edges = Set<[Int]>()
        for line in art.polylines where line.count >= 2 {
            // Round strokes were handled as circles.
            if line.count >= 8 && Geometry2D.distance(line[0], line[line.count - 1]) < max(4, 2.5 * sw) { continue }
            for k in 0..<(line.count - 1) where Geometry2D.distance(line[k], line[k + 1]) > tol * 0.8 {
                let a = node(line[k]), b = node(line[k + 1])
                if a != b { edges.insert([min(a, b), max(a, b)]) }
            }
        }
        // Bridge small gaps where a stroke was broken (a label erased across it, a lifted pen):
        // a free end pointing straight at another free end nearby.
        var degree = [Int](repeating: 0, count: nodes.count)
        for e in edges { degree[e[0]] += 1; degree[e[1]] += 1 }
        func direction(_ i: Int) -> CGPoint? {
            guard let e = edges.first(where: { $0.contains(i) }) else { return nil }
            let other = e[0] == i ? e[1] : e[0]
            let d = CGPoint(x: nodes[i].x - nodes[other].x, y: nodes[i].y - nodes[other].y)
            let l = max(hypot(d.x, d.y), 0.001)
            return CGPoint(x: d.x / l, y: d.y / l)
        }
        let maxGap = max(tol * 4, minSize * 0.6)
        for i in nodes.indices where degree[i] == 1 {
            guard let di = direction(i) else { continue }
            let candidates = nodes.indices.filter { j in
                j != i && degree[j] >= 1 && Geometry2D.distance(nodes[i], nodes[j]) < maxGap && !edges.contains([min(i, j), max(i, j)])
            }
            let best = candidates.filter { j in
                let g = CGPoint(x: nodes[j].x - nodes[i].x, y: nodes[j].y - nodes[i].y)
                let l = max(hypot(g.x, g.y), 0.001)
                return (g.x * di.x + g.y * di.y) / l > 0.95
            }.min { Geometry2D.distance(nodes[i], nodes[$0]) < Geometry2D.distance(nodes[i], nodes[$1]) }
            if let j = best {
                edges.insert([min(i, j), max(i, j)])
                degree[i] += 1; degree[j] += 1
            }
        }
        var adjacency = [[Int]](repeating: [], count: nodes.count)
        for e in edges { adjacency[e[0]].append(e[1]); adjacency[e[1]].append(e[0]) }
        func angle(_ a: Int, _ b: Int) -> CGFloat { atan2(nodes[b].y - nodes[a].y, nodes[b].x - nodes[a].x) }
        for i in adjacency.indices { adjacency[i].sort { angle(i, $0) < angle(i, $1) } }

        // Walk each directed edge once, always turning to the next edge clockwise.
        var used = Set<[Int]>()
        for e in edges {
            for (start, next) in [(e[0], e[1]), (e[1], e[0])] where !used.contains([start, next]) {
                var face = [start]
                var (u, v) = (start, next)
                var ok = true
                while true {
                    used.insert([u, v])
                    if v == start { break }
                    face.append(v)
                    guard face.count <= 14 else { ok = false; break }
                    let around = adjacency[v]
                    guard let back = around.firstIndex(of: u) else { ok = false; break }
                    let w = around[(back - 1 + around.count) % around.count]
                    (u, v) = (v, w)
                    if used.contains([u, v]) && v != start { ok = false; break }
                }
                guard ok, face.count >= 3 else { continue }
                var points = face.map { nodes[$0] }
                // Signed area: interior faces wind one way, the outer face the other.
                var area: CGFloat = 0
                for k in points.indices {
                    let p = points[k], q = points[(k + 1) % points.count]
                    area += p.x * q.y - q.x * p.y
                }
                guard area > 0 else { continue }
                points = mergeCollinear(mergeClose(points))
                guard points.count >= 3 else { continue }
                let xs = points.map(\.x), ys = points.map(\.y)
                let w = (xs.max() ?? 0) - (xs.min() ?? 0), h = (ys.max() ?? 0) - (ys.min() ?? 0)
                guard max(w, h) >= minSize, min(w, h) >= minSize * 0.15, area / 2 >= minSize * minSize * 0.08 else { continue }
                let c = CGPoint(x: xs.reduce(0, +) / CGFloat(xs.count), y: ys.reduce(0, +) / CGFloat(ys.count))
                result.append(Shape(kind: classify(points), vertices: points, center: c, radius: 0))
            }
        }
        // Biggest first; at most a dozen (tables of cells aren't shapes worth listing).
        return Array(result.sorted { size($0) > size($1) }.prefix(12))
    }

    static func size(_ s: Shape) -> CGFloat {
        if s.kind == .circle { return s.radius * 2 }
        let xs = s.vertices.map(\.x), ys = s.vertices.map(\.y)
        return max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// Merges corners closer than a fraction of the shape's size (jogs where two outlines touch).
    static func mergeClose(_ p: [CGPoint]) -> [CGPoint] {
        var points = p
        let xs = p.map(\.x), ys = p.map(\.y)
        let span = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        let limit = max(8, span * 0.16)
        var changed = true
        while changed && points.count > 3 {
            changed = false
            for k in points.indices {
                let n = (k + 1) % points.count
                if Geometry2D.distance(points[k], points[n]) < limit {
                    points[k] = CGPoint(x: (points[k].x + points[n].x) / 2, y: (points[k].y + points[n].y) / 2)
                    points.remove(at: n)
                    changed = true
                    break
                }
            }
        }
        return points
    }

    static func mergeCollinear(_ p: [CGPoint]) -> [CGPoint] {
        var points = p
        var changed = true
        while changed && points.count > 3 {
            changed = false
            for k in points.indices {
                let a = points[(k - 1 + points.count) % points.count], b = points[k], c = points[(k + 1) % points.count]
                let turn = abs(Geometry2D.normalize(atan2(c.y - b.y, c.x - b.x) - atan2(b.y - a.y, b.x - a.x)))
                if turn < 0.14 { points.remove(at: k); changed = true; break }
            }
        }
        return points
    }

    /// Interior angle at each vertex, degrees.
    static func angles(_ p: [CGPoint]) -> [Double] {
        p.indices.map { k in
            let a = p[(k - 1 + p.count) % p.count], b = p[k], c = p[(k + 1) % p.count]
            let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let cosine = (v1.x * v2.x + v1.y * v2.y) / max(hypot(v1.x, v1.y) * hypot(v2.x, v2.y), 0.001)
            return Double(acos(max(-1, min(1, cosine)))) * 180 / .pi
        }
    }

    static func classify(_ p: [CGPoint]) -> Shape.Kind {
        switch p.count {
        case 3: return .triangle
        case 4:
            let right = angles(p).allSatisfy { abs($0 - 90) < 10 }
            guard right else { return .quadrilateral }
            let a = Geometry2D.distance(p[0], p[1]), b = Geometry2D.distance(p[1], p[2])
            return abs(a - b) < 0.12 * max(a, b) ? .square : .rectangle
        default: return .polygon
        }
    }
}
