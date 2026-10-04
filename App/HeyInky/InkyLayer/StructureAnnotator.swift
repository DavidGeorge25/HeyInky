import CoreGraphics
import Foundation

/// Compiles an `annotateStructure` action into ordinary Inky marks (`draw`, `label`) with exact
/// geometry on the recognized structure: hydrogens fanned into the open angles at each atom at the
/// drawing's own bond length, lone pairs and charges in free space, marker highlights along the
/// real bonds, and curved mechanism arrows that bow away from the molecule. The model says *what*;
/// this decides *where*.
enum StructureAnnotator {
    struct Output {
        var actions: [InkyAction] = []
        /// What couldn't be done (unknown atoms, unmatched groups), for the toast/retry.
        var problems: [String] = []
    }

    /// Valence electrons for lone-pair counting.
    static let valenceElectrons: [String: Int] = ["C": 4, "N": 5, "O": 6, "S": 6, "P": 5, "F": 7, "Cl": 7, "Br": 7, "I": 7, "B": 3, "Se": 6]

    /// - Parameter groupAtoms: atom indices matched for each highlight's `group` (by the caller via
    ///   RDKit), keyed by highlight index. Highlights with a group and no entry are reported.
    static func compile(_ action: AnnotateStructureAction, structure input: PageStructure, pageSize: CGSize,
                        groupAtoms: [Int: [Int]] = [:]) -> Output {
        var out = Output()
        let structure = applyRelabels(action.relabel, to: input)
        var geometry = Geometry(structure: structure, pageSize: pageSize)

        func atom(_ id: String) -> Int? {
            if let i = structure.atomIndex(id) { return i }
            out.problems.append("\(structure.id) has no atom \(id)")
            return nil
        }
        func atomList(_ ids: [String], all: () -> [Int]) -> [Int] {
            if ids.contains(where: { $0.lowercased() == "all" }) { return all() }
            return ids.compactMap(atom)
        }

        // 1. Highlights first (they go under everything).
        var markerShapes: [DrawAction.Color: [DrawAction.Shape]] = [:]
        var notes: [DrawAction.Shape] = []
        for (h, highlight) in action.highlights.enumerated() {
            var atoms = Set(highlight.atoms.compactMap(atom))
            if highlight.group != nil {
                if let matched = groupAtoms[h], !matched.isEmpty {
                    atoms.formUnion(matched)
                } else if atoms.isEmpty {
                    out.problems.append("no \(highlight.group ?? "group") found in \(structure.id)")
                    continue
                }
            }
            guard !atoms.isEmpty else { continue }
            let color = markerColor(highlight.color)
            markerShapes[color, default: []] += geometry.highlightShapes(atoms: atoms)
            if let note = highlight.note?.trimmingCharacters(in: .whitespaces), !note.isEmpty {
                notes.append(geometry.noteShape(note, near: atoms))
            }
        }
        for (color, shapes) in markerShapes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !shapes.isEmpty {
            out.actions.append(.draw(DrawAction(ink: .marker, color: color, shapes: shapes, caption: "highlight on \(structure.id)")))
        }

        // 2. Hydrogens.
        let hydrogenAtoms = atomList(action.hydrogens) { structure.atoms.indices.filter { structure.atoms[$0].hiddenHydrogens > 0 && structure.atoms[$0].element != "?" } }
        var hShapes: [DrawAction.Shape] = []
        for i in hydrogenAtoms {
            let count = min(4, structure.atoms[i].hiddenHydrogens)
            guard count > 0 else { continue }
            for (start, end) in geometry.placeHydrogens(atom: i, count: count) {
                hShapes.append(.init(kind: .line, points: [geometry.norm(start), geometry.norm(end)], text: nil, size: .small))
                hShapes.append(.init(kind: .text, points: [geometry.norm(end)], text: "H", size: .small))
            }
        }
        if !hShapes.isEmpty {
            out.actions.append(.draw(DrawAction(ink: .pen, color: action.color, shapes: hShapes, caption: "hydrogens on \(structure.id)")))
        }

        // 3. Lone pairs.
        let lonePairAtoms = atomList(action.lonePairs) { structure.atoms.indices.filter { lonePairs(structure, $0) > 0 } }
        var lpShapes: [DrawAction.Shape] = []
        for i in lonePairAtoms {
            let count = lonePairs(structure, i)
            for dots in geometry.placeLonePairs(atom: i, count: count) {
                for dot in dots {
                    lpShapes.append(.init(kind: .ellipse, points: [geometry.norm(CGPoint(x: dot.x - 1.1, y: dot.y - 1.1)), geometry.norm(CGPoint(x: dot.x + 1.1, y: dot.y + 1.1))], text: nil, size: .small))
                }
            }
        }
        if !lpShapes.isEmpty {
            out.actions.append(.draw(DrawAction(ink: .pen, color: action.color, shapes: lpShapes, caption: "lone pairs on \(structure.id)")))
        }

        // 4. Charges.
        var chargeShapes: [DrawAction.Shape] = []
        for charge in action.charges {
            guard let i = atom(charge.atom) else { continue }
            chargeShapes.append(.init(kind: .text, points: [geometry.norm(geometry.placeCharge(atom: i, text: charge.text))], text: charge.text, size: .small))
        }
        if !chargeShapes.isEmpty {
            let color: DrawAction.Color = action.charges.contains { $0.text.hasPrefix("δ") } ? .blue : action.color
            out.actions.append(.draw(DrawAction(ink: .pen, color: color, shapes: chargeShapes, caption: "charges on \(structure.id)")))
        }

        // 5. Mechanism arrows.
        var arrowShapes: [DrawAction.Shape] = []
        for arrow in action.arrows {
            guard let from = geometry.endpoint(arrow.from, asSource: true, problems: &out.problems),
                  let to = geometry.endpoint(arrow.to, asSource: false, problems: &out.problems) else { continue }
            arrowShapes += geometry.curvedArrow(from: from, to: to, fishhook: arrow.kind == .fishhook)
        }
        if !arrowShapes.isEmpty {
            out.actions.append(.draw(DrawAction(ink: .pen, color: .red, shapes: arrowShapes, caption: "mechanism arrows on \(structure.id)")))
        }

        // 6. Notes for highlights, then atom labels.
        if !notes.isEmpty {
            out.actions.append(.draw(DrawAction(ink: .pen, color: action.color, shapes: notes, caption: "notes on \(structure.id)")))
        }
        for label in action.labels {
            guard let i = atom(label.atom) else { continue }
            out.actions.append(.label(LabelAction(anchor: geometry.norm(geometry.labelAnchor(atom: i)), text: label.text, arrow: true)))
        }
        return out
    }

    static func lonePairs(_ structure: PageStructure, _ i: Int) -> Int {
        let atom = structure.atoms[i]
        guard let valence = valenceElectrons[atom.element], atom.element != "C" || atom.charge < 0 else { return 0 }
        let bonded = structure.bonds.filter { $0.a == i || $0.b == i }.reduce(0) { $0 + $1.order }
        return max(0, (valence - bonded - atom.hydrogens - atom.charge) / 2)
    }

    static func applyRelabels(_ relabels: [AnnotateStructureAction.Relabel], to structure: PageStructure) -> PageStructure {
        var s = structure
        for r in relabels {
            guard let i = s.atomIndex(r.atom), let reading = AtomLabelReader.parse(r.symbol) else { continue }
            let bonded = s.bonds.filter { $0.a == i || $0.b == i }.reduce(0) { $0 + $1.order }
            s.atoms[i].element = reading.element
            s.atoms[i].label = reading.text
            s.atoms[i].writtenHydrogens = reading.writtenHydrogens
            s.atoms[i].hydrogens = max(reading.writtenHydrogens, (PageStructureFinder.valence[reading.element] ?? 0) - bonded)
            s.atoms[i].unsure = false
        }
        return s
    }

    static func markerColor(_ c: HighlightColor) -> DrawAction.Color {
        switch c {
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .pink: .pink
        case .orange: .orange
        }
    }

    // MARK: Geometry (page points)

    struct Geometry {
        let structure: PageStructure
        let pageSize: CGSize
        let points: [CGPoint]
        let bondLength: CGFloat
        let centroid: CGPoint
        /// Directions of new things already placed per atom (radians), so later items avoid them.
        var used: [Int: [CGFloat]] = [:]
        /// Centers of new labels/dots placed so far.
        var placed: [CGPoint] = []

        init(structure: PageStructure, pageSize: CGSize) {
            self.structure = structure
            self.pageSize = pageSize
            points = structure.atoms.map { $0.point.cgPoint(in: pageSize) }
            bondLength = max(12, CGFloat(structure.bondLength))
            let n = CGFloat(max(1, points.count))
            var sx: CGFloat = 0, sy: CGFloat = 0
            for p in points { sx += p.x; sy += p.y }
            centroid = CGPoint(x: sx / n, y: sy / n)
        }

        func norm(_ p: CGPoint) -> NormPoint {
            NormPoint(x: min(max(p.x / pageSize.width, 0), 1), y: min(max(p.y / pageSize.height, 0), 1))
        }

        /// How far from the atom center new ink starts: past its letter, at the vertex otherwise.
        func radius(_ i: Int) -> CGFloat {
            guard let box = structure.atoms[i].labelBox?.cgRect(in: pageSize) else { return 0 }
            return min(box.height * 0.5 + 3, bondLength * 0.45)
        }

        /// The written part of a label beyond the heavy-atom letter ("H" of "OH"), kept clear.
        func labelObstacles(_ i: Int) -> [CGPoint] {
            guard let box = structure.atoms[i].labelBox?.cgRect(in: pageSize), box.width > box.height * 1.3 else { return [] }
            let p = points[i]
            // Points along the label away from the atom's letter.
            return stride(from: box.minX + box.height * 0.5, through: box.maxX - box.height * 0.3, by: max(4, box.height * 0.5))
                .map { CGPoint(x: $0, y: box.midY) }
                .filter { abs($0.x - p.x) > box.height * 0.45 }
        }

        func bondAngles(_ i: Int) -> [CGFloat] {
            structure.neighbors(of: i).map { atan2(points[$0].y - points[i].y, points[$0].x - points[i].x) }
        }

        /// Directions for `count` new items around atom `i`: spread through the open angles
        /// (bigger gaps get more), then nudged away from nearby atoms and earlier placements.
        mutating func directions(atom i: Int, count: Int, reach: CGFloat) -> [CGFloat] {
            // The written H's of a label ("OH") occupy a direction like a bond does.
            let labelSide = labelObstacles(i).map { atan2($0.y - points[i].y, $0.x - points[i].x) }
            let labelAngle: [CGFloat] = labelSide.isEmpty ? [] : [atan2(labelSide.map(sin).reduce(0, +), labelSide.map(cos).reduce(0, +))]
            let taken = (bondAngles(i) + labelAngle + (used[i] ?? [])).map { Self.wrap($0) }.sorted()
            var result: [CGFloat] = []
            if taken.isEmpty {
                let step: CGFloat = 2 * CGFloat.pi / CGFloat(count)
                for k in 0..<count { result.append(-CGFloat.pi / 2 + step * CGFloat(k)) }
            } else {
                // Gaps (start, size).
                var gaps: [(CGFloat, CGFloat)] = []
                for (k, a) in taken.enumerated() {
                    let next = k + 1 < taken.count ? taken[k + 1] : taken[0] + 2 * .pi
                    gaps.append((a, next - a))
                }
                var assigned = [Int](repeating: 0, count: gaps.count)
                for _ in 0..<count {
                    let g = gaps.indices.max { gaps[$0].1 / CGFloat(assigned[$0] + 1) < gaps[$1].1 / CGFloat(assigned[$1] + 1) }!
                    assigned[g] += 1
                }
                for (g, n) in assigned.enumerated() where n > 0 {
                    for j in 0..<n { result.append(gaps[g].0 + gaps[g].1 * CGFloat(j + 1) / CGFloat(n + 1)) }
                }
            }
            // Nudge each within ±25° for clearance from other atoms, labels and placed items.
            let others = points.indices.filter { $0 != i }.map { points[$0] } + placed + labelObstacles(i)
            let bonds = Set(bondAngles(i).map { Self.wrap($0) })
            result = result.map { base in
                var best = base, bestScore = -CGFloat.infinity
                for step in stride(from: -25.0, through: 25.0, by: 5.0) {
                    let a = base + CGFloat(step) * .pi / 180
                    // Stay clear of the atom's own bonds.
                    if bonds.contains(where: { abs(Self.wrap(a - $0 + .pi) - .pi) < 0.45 }) { continue }
                    let tip = CGPoint(x: points[i].x + cos(a) * reach, y: points[i].y + sin(a) * reach)
                    let clearance = others.map { hypot($0.x - tip.x, $0.y - tip.y) }.min() ?? bondLength
                    let score = min(clearance, bondLength) - abs(CGFloat(step)) * 0.08
                    if score > bestScore { bestScore = score; best = a }
                }
                return best
            }
            used[i, default: []] += result
            return result
        }

        mutating func placeHydrogens(atom i: Int, count: Int) -> [(CGPoint, CGPoint)] {
            let r0 = radius(i)
            let length = bondLength * 0.6
            return directions(atom: i, count: count, reach: r0 + length + 7).map { a in
                let u = CGPoint(x: cos(a), y: sin(a))
                let start = CGPoint(x: points[i].x + u.x * r0, y: points[i].y + u.y * r0)
                let end = CGPoint(x: start.x + u.x * length, y: start.y + u.y * length)
                placed.append(CGPoint(x: end.x + u.x * 7, y: end.y + u.y * 7))
                return (start, end)
            }
        }

        /// Pairs of dot centers.
        mutating func placeLonePairs(atom i: Int, count: Int) -> [[CGPoint]] {
            guard count > 0 else { return [] }
            let r = max(radius(i), 5) + bondLength * 0.12
            return directions(atom: i, count: count, reach: r).map { a in
                let u = CGPoint(x: cos(a), y: sin(a)), n = CGPoint(x: -sin(a), y: cos(a))
                let c = CGPoint(x: points[i].x + u.x * r, y: points[i].y + u.y * r)
                placed.append(c)
                return [CGPoint(x: c.x + n.x * 3.4, y: c.y + n.y * 3.4), CGPoint(x: c.x - n.x * 3.4, y: c.y - n.y * 3.4)]
            }
        }

        /// Upper right when free, otherwise the most open direction.
        mutating func placeCharge(atom i: Int, text: String) -> CGPoint {
            let r = max(radius(i), 4) + bondLength * 0.22
            let preferred: CGFloat = -.pi / 4
            let taken = bondAngles(i) + (used[i] ?? [])
            let free = taken.allSatisfy { abs(Self.wrap($0 - preferred + .pi) - .pi) > 0.6 }
            let a = free ? preferred : directions(atom: i, count: 1, reach: r)[0]
            if free { used[i, default: []].append(a) }
            let p = CGPoint(x: points[i].x + cos(a) * r, y: points[i].y + sin(a) * r)
            placed.append(p)
            return p
        }

        /// Where a label's arrow touches the atom: just outside it, on its open side.
        mutating func labelAnchor(atom i: Int) -> CGPoint {
            let a = directions(atom: i, count: 1, reach: bondLength * 0.4)[0]
            let r = radius(i) + 3
            return CGPoint(x: points[i].x + cos(a) * r, y: points[i].y + sin(a) * r)
        }

        /// Marker strokes over the bonds within `atoms`, or dabs on lone atoms.
        func highlightShapes(atoms: Set<Int>) -> [DrawAction.Shape] {
            var shapes: [DrawAction.Shape] = []
            var covered = Set<Int>()
            for bond in structure.bonds where atoms.contains(bond.a) && atoms.contains(bond.b) {
                shapes.append(.init(kind: .line, points: [norm(points[bond.a]), norm(points[bond.b])], text: nil, size: .large))
                covered.insert(bond.a)
                covered.insert(bond.b)
            }
            for i in atoms where !covered.contains(i) {
                let r = max(radius(i), bondLength * 0.18)
                shapes.append(.init(kind: .line, points: [norm(CGPoint(x: points[i].x - r, y: points[i].y)), norm(CGPoint(x: points[i].x + r, y: points[i].y))], text: nil, size: .large))
            }
            return shapes
        }

        /// A highlight's name, written outside the structure beside the group.
        func noteShape(_ text: String, near atoms: Set<Int>) -> DrawAction.Shape {
            var sx: CGFloat = 0, sy: CGFloat = 0
            for i in atoms { sx += points[i].x; sy += points[i].y }
            let c = CGPoint(x: sx / CGFloat(max(1, atoms.count)), y: sy / CGFloat(max(1, atoms.count)))
            var d = CGPoint(x: c.x - centroid.x, y: c.y - centroid.y)
            let l = hypot(d.x, d.y)
            d = l > 1 ? CGPoint(x: d.x / l, y: d.y / l) : CGPoint(x: 0, y: -1)
            let (size, _) = DrawInk.measure(text, size: .small, pageSize: pageSize)
            let anchor = CGPoint(x: c.x + d.x * bondLength * 1.05, y: c.y + d.y * bondLength * 0.9)
            let topLeft = CGPoint(x: anchor.x - size.width / 2 + d.x * size.width * 0.3, y: anchor.y - size.height / 2)
            // Long text is placed by its top-left corner; short text by its center.
            let point = DrawInk.isShortLabel(text) ? anchor : topLeft
            return .init(kind: .text, points: [norm(point)], text: text, size: .small)
        }

        /// An arrow end: an atom (its lone pair when it's the source) or a bond/gap "a3-a4".
        mutating func endpoint(_ ref: String, asSource: Bool, problems: inout [String]) -> CGPoint? {
            let parts = ref.split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "=" || $0 == "," })
            if parts.count == 2 {
                guard let a = structure.atomIndex(String(parts[0])), let b = structure.atomIndex(String(parts[1])) else {
                    problems.append("\(structure.id) has no bond \(ref)")
                    return nil
                }
                return CGPoint(x: (points[a].x + points[b].x) / 2, y: (points[a].y + points[b].y) / 2)
            }
            guard let i = structure.atomIndex(ref) else {
                problems.append("\(structure.id) has no atom \(ref)")
                return nil
            }
            if asSource {
                // From the atom's open side, where its lone pair is drawn.
                let a = directions(atom: i, count: 1, reach: bondLength * 0.4)[0]
                let r = max(radius(i), 4) + bondLength * 0.14
                return CGPoint(x: points[i].x + cos(a) * r, y: points[i].y + sin(a) * r)
            }
            return points[i]
        }

        /// A curved arrow bowing away from the molecule, with a full head (or a fishhook barb).
        func curvedArrow(from: CGPoint, to rawTo: CGPoint, fishhook: Bool) -> [DrawAction.Shape] {
            let mid = CGPoint(x: (from.x + rawTo.x) / 2, y: (from.y + rawTo.y) / 2)
            let d = CGPoint(x: rawTo.x - from.x, y: rawTo.y - from.y)
            let dist = max(hypot(d.x, d.y), 1)
            var n = CGPoint(x: -d.y / dist, y: d.x / dist)
            if (mid.x - centroid.x) * n.x + (mid.y - centroid.y) * n.y < 0 { n = CGPoint(x: -n.x, y: -n.y) }
            let bow = max(dist * 0.42, bondLength * 0.45)
            let control = CGPoint(x: mid.x + n.x * bow, y: mid.y + n.y * bow)
            // Stop a little short of the target so the head doesn't sit on the atom.
            let back = CGPoint(x: rawTo.x - control.x, y: rawTo.y - control.y)
            let bl = max(hypot(back.x, back.y), 1)
            let to = CGPoint(x: rawTo.x - back.x / bl * 5, y: rawTo.y - back.y / bl * 5)
            var curve: [CGPoint] = []
            for k in 0...14 {
                let t = CGFloat(k) / 14
                let x = (1 - t) * (1 - t) * from.x + 2 * (1 - t) * t * control.x + t * t * to.x
                let y = (1 - t) * (1 - t) * from.y + 2 * (1 - t) * t * control.y + t * t * to.y
                curve.append(CGPoint(x: x, y: y))
            }
            let u = CGPoint(x: back.x / bl, y: back.y / bl)
            let head = max(6, bondLength * 0.2)
            func barb(_ side: CGFloat) -> CGPoint {
                let a = atan2(u.y, u.x) + .pi + side * 0.45
                return CGPoint(x: to.x + cos(a) * head, y: to.y + sin(a) * head)
            }
            var shapes: [DrawAction.Shape] = [.init(kind: .polyline, points: curve.map(norm), text: nil, size: .medium)]
            // The outer barb (away from the molecule) for a fishhook.
            let outer: CGFloat = (n.x * -u.y + n.y * u.x) > 0 ? 1 : -1
            for side in fishhook ? [outer] : [1, -1] {
                shapes.append(.init(kind: .line, points: [norm(to), norm(barb(side))], text: nil, size: .medium))
            }
            return shapes
        }

        static func wrap(_ a: CGFloat) -> CGFloat {
            var a = a.truncatingRemainder(dividingBy: 2 * .pi)
            if a < 0 { a += 2 * .pi }
            return a
        }
    }
}
