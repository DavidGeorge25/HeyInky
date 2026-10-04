import CoreGraphics
import Foundation

/// Line art → a bond graph, the way a chemist reads a skeletal drawing: straight strokes are
/// bonds, their ends and corners are atoms, clusters of small curvy strokes are atom labels
/// ("O", "NH", "OH"), and parallel strokes are double/triple bonds.
///
/// Works in any coordinate space (bitmap pixels here); every threshold is relative to the
/// drawing's own bond length and stroke width, so size and resolution don't matter.
enum StructureRecognizer {
    struct Segment: Sendable {
        var a: CGPoint
        var b: CGPoint
        var order = 1
        var isGlyph = false
        var path: Int
        var length: CGFloat { hypot(b.x - a.x, b.y - a.y) }
        var mid: CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var angle: CGFloat { atan2(b.y - a.y, b.x - a.x) }
    }

    /// A cluster of letter strokes: one atom label.
    struct Glyph: Sendable {
        var box: CGRect
    }

    struct Atom: Sendable {
        var point: CGPoint
        /// Index into `glyphs` when the atom is written as letters.
        var glyph: Int?
        var bonds: [Int] = []
    }

    struct Bond: Sendable {
        var a: Int
        var b: Int
        var order: Int
    }

    struct Graph: Sendable {
        var bondLength: CGFloat
        var glyphs: [Glyph]
        var atoms: [Atom]
        var bonds: [Bond]
        /// Bond line pieces used (for debugging/tests).
        var bondSegments: [Segment]

        static let empty = Graph(bondLength: 0, glyphs: [], atoms: [], bonds: [], bondSegments: [])

        func neighbors(of atom: Int) -> [Int] {
            atoms[atom].bonds.map { bonds[$0].a == atom ? bonds[$0].b : bonds[$0].a }
        }

        /// Connected components (atom index lists), largest first.
        func components() -> [[Int]] {
            var seen = Set<Int>()
            var result: [[Int]] = []
            for start in atoms.indices where !seen.contains(start) {
                var stack = [start], members: [Int] = []
                seen.insert(start)
                while let a = stack.popLast() {
                    members.append(a)
                    for n in neighbors(of: a) where !seen.contains(n) { seen.insert(n); stack.append(n) }
                }
                result.append(members.sorted())
            }
            return result.sorted { $0.count > $1.count }
        }
    }

    static func recognize(_ art: LineArt) -> Graph {
        recognize(polylines: art.polylines, strokeWidth: art.strokeWidth)
    }

    static func recognize(polylines: [[CGPoint]], strokeWidth sw: CGFloat) -> Graph {
        typealias G = Geometry2D
        // 1. Segments.
        var segments: [Segment] = []
        var closed: [Bool] = []
        for (p, line) in polylines.enumerated() {
            closed.append(line.count > 3 && G.distance(line[0], line[line.count - 1]) < max(2, sw))
            for i in 0..<max(0, line.count - 1) where G.distance(line[i], line[i + 1]) > 0.01 {
                segments.append(Segment(a: line[i], b: line[i + 1], path: p))
            }
        }

        // 2. Bond length: the typical length of the long straight strokes.
        let lengths = segments.map(\.length).filter { $0 > 3 * sw }.sorted(by: >)
        guard !lengths.isEmpty else { return .empty }
        let p90 = lengths[min(lengths.count - 1, lengths.count / 10)]
        let long = lengths.filter { $0 >= 0.55 * p90 }
        let L = long[long.count / 2]
        guard L > 4 * sw else { return .empty }

        // 3. Letter pieces: small curvy or closed paths, and short pieces.
        var boxes: [CGRect] = []
        for line in polylines {
            let xs = line.map(\.x), ys = line.map(\.y)
            boxes.append(CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0)))
        }
        for i in segments.indices {
            let s = segments[i]
            let box = boxes[s.path]
            let small = max(box.width, box.height) < 0.75 * L
            let pieces = polylines[s.path].count - 1
            if closed[s.path] && small { segments[i].isGlyph = true; continue }
            if small && pieces >= 3 { segments[i].isGlyph = true; continue }
            if s.length < 0.38 * L && s.length >= 1.2 * sw { segments[i].isGlyph = true }
        }

        var glyphs: [Glyph] = []
        var assigned = Set<Int>()
        let glyphIndices = segments.indices.filter { segments[$0].isGlyph }
        for i in glyphIndices where !assigned.contains(i) {
            var members = [i]
            assigned.insert(i)
            var k = 0
            while k < members.count {
                let m = segments[members[k]]
                for j in glyphIndices where !assigned.contains(j) && segmentDistance(m, segments[j]) < 0.3 * L {
                    assigned.insert(j)
                    members.append(j)
                }
                k += 1
            }
            var box = CGRect.null
            for m in members {
                let s = segments[m]
                box = box.union(CGRect(x: min(s.a.x, s.b.x), y: min(s.a.y, s.b.y), width: abs(s.a.x - s.b.x), height: abs(s.a.y - s.b.y)))
            }
            let ink = members.reduce(0) { $0 + segments[$1].length }
            let isLetter = ink >= 0.35 * L && max(box.width, box.height) <= 1.6 * L
                && box.height >= 0.2 * L && max(box.width, box.height) >= 0.25 * L
            if isLetter {
                glyphs.append(Glyph(box: box))
            } else {
                for m in members { segments[m].isGlyph = false }
            }
        }

        // 4. Bond lines: everything else; rejoin straight lines split at junctions.
        var bondSegs = segments.filter { !$0.isGlyph && $0.length >= 1.2 * sw }
        var rejoined = true
        while rejoined {
            rejoined = false
            outer: for i in bondSegs.indices {
                for j in bondSegs.indices where j != i {
                    let s = bondSegs[i], t = bondSegs[j]
                    for (p, q, far1, far2) in [(s.b, t.a, s.a, t.b), (s.b, t.b, s.a, t.a), (s.a, t.a, s.b, t.b), (s.a, t.b, s.b, t.a)]
                    where G.distance(p, q) < 0.35 * L {
                        let merged = Segment(a: far1, b: far2, path: s.path)
                        let tol = max(2, 1.2 * sw)
                        guard merged.length > max(s.length, t.length) + G.distance(p, q) * 0.5, merged.length < 1.5 * L,
                              G.distance(p, toLine: far1, far2) < tol, G.distance(q, toLine: far1, far2) < tol else { continue }
                        let gap = G.distance(p, q)
                        let gapMid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
                        let crowded = bondSegs.indices.contains { k in
                            k != i && k != j
                                && (G.distance(bondSegs[k].a, gapMid) < max(0.2 * L, gap) || G.distance(bondSegs[k].b, gapMid) < max(0.2 * L, gap))
                                && G.distance(bondSegs[k].mid, toLine: far1, far2) > tol
                                && projectionOverlap(bondSegs[k], onto: merged) < 0.5 * bondSegs[k].length
                        }
                        guard !crowded else { continue }
                        var m = merged
                        m.order = max(s.order, t.order)
                        bondSegs[i] = m
                        bondSegs.remove(at: j)
                        rejoined = true
                        break outer
                    }
                }
            }
        }
        bondSegs.removeAll { $0.length < 0.3 * L }
        // A line drawn inside a letter (the diagonal of an N) is part of the letter.
        bondSegs.removeAll { s in
            glyphs.contains { $0.box.insetBy(dx: -sw, dy: -sw).contains(s.a) && $0.box.insetBy(dx: -sw, dy: -sw).contains(s.b) }
        }

        // 5. Parallel lines → double/triple bonds (before ends are merged into atoms).
        func connected(_ p: CGPoint, excluding: Set<Int>) -> Bool {
            bondSegs.indices.contains { j in
                !excluding.contains(j) && (G.distance(bondSegs[j].a, p) < 0.28 * L || G.distance(bondSegs[j].b, p) < 0.28 * L)
            } || glyphs.contains { $0.box.insetBy(dx: -0.3 * L, dy: -0.3 * L).contains(p) }
        }
        var merged = true
        while merged {
            merged = false
            outer: for i in bondSegs.indices {
                for j in bondSegs.indices where j > i {
                    let s = bondSegs[i], t = bondSegs[j]
                    var d = abs(s.angle - t.angle).truncatingRemainder(dividingBy: .pi)
                    d = min(d, .pi - d)
                    guard d < 0.22 else { continue }
                    let (longer, shorter) = s.length >= t.length ? (s, t) : (t, s)
                    let gap = G.distance(shorter.mid, toLine: longer.a, longer.b)
                    guard gap > 0.6 * sw, gap < 0.42 * L, projectionOverlap(shorter, onto: longer) > 0.55 * shorter.length else { continue }
                    let sConnected = connected(s.a, excluding: [i, j]) && connected(s.b, excluding: [i, j])
                    let tConnected = connected(t.a, excluding: [i, j]) && connected(t.b, excluding: [i, j])
                    var keep: Segment
                    if sConnected && !tConnected {
                        keep = s
                    } else if tConnected && !sConnected {
                        keep = t
                    } else {
                        // Symmetric pair (C=O drawn as two equal lines): the bond runs between them.
                        let aligned = G.distance(t.a, s.a) < G.distance(t.b, s.a) ? t : Segment(a: t.b, b: t.a, path: t.path)
                        keep = Segment(a: CGPoint(x: (s.a.x + aligned.a.x) / 2, y: (s.a.y + aligned.a.y) / 2),
                                       b: CGPoint(x: (s.b.x + aligned.b.x) / 2, y: (s.b.y + aligned.b.y) / 2), path: s.path)
                    }
                    keep.order = min(3, s.order + t.order)
                    bondSegs[i] = keep
                    bondSegs.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }

        // 6. Atoms: letters first, then clustered line ends.
        var atoms: [Atom] = glyphs.indices.map { Atom(point: CGPoint(x: glyphs[$0].box.midX, y: glyphs[$0].box.midY), glyph: $0) }
        func atomIndex(for p: CGPoint) -> Int {
            if let g = glyphs.indices.min(by: { G.distance(p, toRect: glyphs[$0].box) < G.distance(p, toRect: glyphs[$1].box) }),
               G.distance(p, toRect: glyphs[g].box) < 0.32 * L { return g }
            if let a = atoms.indices.filter({ atoms[$0].glyph == nil }).min(by: { G.distance(atoms[$0].point, p) < G.distance(atoms[$1].point, p) }),
               G.distance(atoms[a].point, p) < 0.3 * L { return a }
            atoms.append(Atom(point: p))
            return atoms.count - 1
        }
        var ends: [(Int, Int)] = bondSegs.map { (atomIndex(for: $0.a), atomIndex(for: $0.b)) }

        // A free line end pointing at a nearby label is bonded to it (students leave a gap).
        func degree(_ a: Int) -> Int { ends.reduce(0) { $0 + ($1.0 == a ? 1 : 0) + ($1.1 == a ? 1 : 0) } }
        for k in ends.indices {
            for side in 0..<2 {
                let a = side == 0 ? ends[k].0 : ends[k].1
                guard atoms[a].glyph == nil, degree(a) == 1 else { continue }
                let p = atoms[a].point, other = atoms[side == 0 ? ends[k].1 : ends[k].0].point
                let dir = CGPoint(x: p.x - other.x, y: p.y - other.y)
                let candidates = glyphs.indices.filter { g in
                    let c = CGPoint(x: glyphs[g].box.midX, y: glyphs[g].box.midY)
                    return (c.x - p.x) * dir.x + (c.y - p.y) * dir.y > 0 && G.distance(p, toRect: glyphs[g].box) < 0.6 * L
                }
                if let g = candidates.min(by: { G.distance(p, toRect: glyphs[$0].box) < G.distance(p, toRect: glyphs[$1].box) }) {
                    if side == 0 { ends[k].0 = g } else { ends[k].1 = g }
                }
            }
        }

        // Plain atoms sit at the mean of their line ends.
        var sums = [CGPoint](repeating: .zero, count: atoms.count), counts = [Int](repeating: 0, count: atoms.count)
        for (k, s) in bondSegs.enumerated() {
            for (atom, p) in [(ends[k].0, s.a), (ends[k].1, s.b)] where atoms[atom].glyph == nil && G.distance(atoms[atom].point, p) < 0.35 * L {
                sums[atom].x += p.x; sums[atom].y += p.y; counts[atom] += 1
            }
        }
        for i in atoms.indices where counts[i] > 0 {
            atoms[i].point = CGPoint(x: sums[i].x / CGFloat(counts[i]), y: sums[i].y / CGFloat(counts[i]))
        }

        // 7. Bonds; two lines between the same atoms add up.
        var bonds: [Bond] = []
        for (k, s) in bondSegs.enumerated() {
            let (u, v) = ends[k]
            guard u != v else { continue }
            if let existing = bonds.firstIndex(where: { ($0.a == u && $0.b == v) || ($0.a == v && $0.b == u) }) {
                bonds[existing].order = min(3, bonds[existing].order + s.order)
            } else {
                bonds.append(Bond(a: u, b: v, order: s.order))
            }
        }

        // Keep atoms that have bonds (unbonded letters are free text, not atoms).
        let kept = atoms.indices.filter { a in bonds.contains { $0.a == a || $0.b == a } }
        var remap: [Int: Int] = [:]
        for (new, old) in kept.enumerated() { remap[old] = new }
        var finalAtoms = kept.map { Atom(point: atoms[$0].point, glyph: atoms[$0].glyph) }
        let finalBonds = bonds.map { Bond(a: remap[$0.a]!, b: remap[$0.b]!, order: $0.order) }
        for (i, b) in finalBonds.enumerated() {
            finalAtoms[b.a].bonds.append(i)
            finalAtoms[b.b].bonds.append(i)
        }
        return Graph(bondLength: L, glyphs: glyphs, atoms: finalAtoms, bonds: finalBonds, bondSegments: bondSegs)
    }

    // MARK: Geometry

    static func projectionOverlap(_ s: Segment, onto t: Segment) -> CGFloat {
        let dx = t.b.x - t.a.x, dy = t.b.y - t.a.y
        let l = hypot(dx, dy)
        guard l > 0.001 else { return 0 }
        let ux = dx / l, uy = dy / l
        let p1 = (s.a.x - t.a.x) * ux + (s.a.y - t.a.y) * uy
        let p2 = (s.b.x - t.a.x) * ux + (s.b.y - t.a.y) * uy
        return max(0, min(max(p1, p2), l) - max(min(p1, p2), 0))
    }

    static func segmentDistance(_ s: Segment, _ t: Segment) -> CGFloat {
        min(Geometry2D.distance(s.a, toSegment: t.a, t.b), Geometry2D.distance(s.b, toSegment: t.a, t.b),
            Geometry2D.distance(t.a, toSegment: s.a, s.b), Geometry2D.distance(t.b, toSegment: s.a, s.b))
    }

    /// Plausible skeletal chemistry rather than a ramp, table, chart or doodle: consistent bond
    /// lengths (no bond much longer than the others) and bond angles mostly near 109–120°.
    static func looksLikeStructure(_ graph: Graph, atoms component: [Int]) -> Bool {
        let set = Set(component)
        let bonds = graph.bonds.filter { set.contains($0.a) }
        guard bonds.count >= 2, component.count >= 3 else { return false }
        let lengths = bonds.map { Geometry2D.distance(graph.atoms[$0.a].point, graph.atoms[$0.b].point) }.sorted()
        let median = lengths[lengths.count / 2]
        let mean = lengths.reduce(0, +) / CGFloat(lengths.count)
        let sd = sqrt(lengths.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(lengths.count))
        guard mean > 0, sd / mean < 0.35, (lengths.last ?? 0) < median * 2.6, (lengths.first ?? 0) > median * 0.4 else { return false }
        var right = 0, chemical = 0, total = 0
        for a in component {
            let p = graph.atoms[a].point
            let dirs = graph.neighbors(of: a).map { atan2(graph.atoms[$0].point.y - p.y, graph.atoms[$0].point.x - p.x) }
            for i in dirs.indices {
                for j in dirs.indices where j > i {
                    let angle = abs(Geometry2D.normalize(dirs[i] - dirs[j])) * 180 / .pi
                    total += 1
                    if abs(angle - 90) < 8 || angle > 172 { right += 1 }
                    if angle > 95 && angle < 150 { chemical += 1 }
                }
            }
        }
        guard total > 0 else { return true }
        return Double(right) / Double(total) < 0.5 && Double(chemical) / Double(total) >= 0.5
    }
}
