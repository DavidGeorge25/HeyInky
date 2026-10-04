import UIKit

/// Clean geometry for atoms Inky adds to the student's structure. The model decides the chemistry
/// (which atom gets how many H's, OH, Cl…); the app decides the angles: new bonds from a vertex of
/// the student's skeleton fan out evenly into the largest open angle between its existing bonds
/// (a terminal CH₃'s three H's 120° apart, a ring CH₂'s two H's splayed outside the ring, a CH's
/// one H on the outside bisector), at a length that matches the student's bonds.
enum BondLayout {
    /// Points closer than this (page points) are the same atom.
    static let mergeDistance: CGFloat = 10

    struct Skeleton {
        var vertices: [CGPoint] = []
        var neighbors: [Set<Int>] = []
        var bondLength: CGFloat?

        init(paths: [[CGPoint]]) {
            var lengths: [CGFloat] = []
            for path in paths {
                var previous: Int?
                for point in path {
                    let index = vertex(at: point)
                    if let previous, previous != index {
                        neighbors[previous].insert(index)
                        neighbors[index].insert(previous)
                        lengths.append(hypot(vertices[previous].x - vertices[index].x, vertices[previous].y - vertices[index].y))
                    }
                    previous = index
                }
            }
            lengths.sort()
            bondLength = lengths.isEmpty ? nil : lengths[lengths.count / 2]
        }

        private mutating func vertex(at point: CGPoint) -> Int {
            if let i = vertices.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < BondLayout.mergeDistance }) { return i }
            vertices.append(point)
            neighbors.append([])
            return vertices.count - 1
        }

        func nearestVertex(to p: CGPoint, within distance: CGFloat) -> Int? {
            let best = vertices.indices.min { hypot(vertices[$0].x - p.x, vertices[$0].y - p.y) < hypot(vertices[$1].x - p.x, vertices[$1].y - p.y) }
            guard let best, hypot(vertices[best].x - p.x, vertices[best].y - p.y) <= distance else { return nil }
            return best
        }
    }

    /// The skeleton's atoms and how many lines meet at each, for Inky's context.
    static func atoms(skeleton paths: [[NormPoint]], pageSize: CGSize) -> [InkAtom] {
        let skeleton = Skeleton(paths: paths.map { $0.map { $0.cgPoint(in: pageSize) } })
        return skeleton.vertices.indices.map { i in
            InkAtom(point: NormPoint(x: skeleton.vertices[i].x / pageSize.width, y: skeleton.vertices[i].y / pageSize.height),
                    bonds: skeleton.neighbors[i].count)
        }
    }

    /// `action` with every short labeled bond that starts on a skeleton vertex re-aimed and resized.
    static func refine(_ action: DrawAction, skeleton paths: [[NormPoint]], pageSize: CGSize) -> DrawAction {
        let skeleton = Skeleton(paths: paths.map { $0.map { $0.cgPoint(in: pageSize) } })
        guard !skeleton.vertices.isEmpty else { return action }
        let points = action.shapes.map { $0.points.map { $0.cgPoint(in: pageSize) } }

        // A new bond may start a little off the atom it belongs to (the model estimates); a third
        // of a bond length can't reach the wrong atom.
        let attach = max(mergeDistance, (skeleton.bondLength ?? 0) * 0.33)
        // New bonds by the vertex they start from: (line shape, label shape at its far end).
        var groups: [Int: [(line: Int, label: Int?)]] = [:]
        for (i, shape) in action.shapes.enumerated() where shape.kind == .line && points[i].count == 2 {
            let (a, b) = (points[i][0], points[i][1])
            // Either end may touch the structure; the other end is the new atom.
            let (startIndex, start, end): (Int, CGPoint, CGPoint)
            if let v = skeleton.nearestVertex(to: a, within: attach) { (startIndex, start, end) = (v, a, b) }
            else if let v = skeleton.nearestVertex(to: b, within: attach) { (startIndex, start, end) = (v, b, a) }
            else { continue }
            // Not a bond of the structure itself (e.g. the model retracing a skeleton edge).
            if skeleton.nearestVertex(to: end, within: mergeDistance) != nil { continue }
            _ = start
            let label = action.shapes.indices.first { j in
                guard action.shapes[j].kind == .text, let text = action.shapes[j].text, DrawInk.isShortLabel(text), let p = points[j].first else { return false }
                return hypot(p.x - end.x, p.y - end.y) < 18
            }
            groups[startIndex, default: []].append((i, label))
        }
        guard !groups.isEmpty else { return action }

        // A pure "add the hydrogens" drawing: every label is H and every line is a new bond.
        let grouped = Set(groups.values.flatMap { $0.map(\.line) })
        let lineIndices = action.shapes.indices.filter { action.shapes[$0].kind == .line }
        let labels = action.shapes.filter { $0.kind == .text }.compactMap { $0.text?.trimmingCharacters(in: .whitespaces) }
        let hydrogenOnly = !labels.isEmpty && labels.allSatisfy { $0 == "H" } && Set(lineIndices) == grouped
            && action.shapes.allSatisfy { $0.kind == .line || $0.kind == .text }

        // Chemistry check: a junction without a letter is a carbon, so it takes at most
        // 4 − (lines meeting) hydrogens. Extra H's (the model drawing one carbon's H's twice)
        // are dropped, keeping the bonds that start closest to the atom.
        var dropped = Set<Int>()
        for (vertex, bonds) in groups {
            // In a hydrogen drawing an unlabeled bond is a C–H whose label the model misplaced.
            let hydrogens = bonds.filter { b in b.label.map { action.shapes[$0].text?.trimmingCharacters(in: .whitespaces) == "H" } ?? hydrogenOnly }
            let room = max(0, 4 - skeleton.neighbors[vertex].count)
            guard hydrogens.count > room else { continue }
            let origin = skeleton.vertices[vertex]
            let byDistance = hydrogens.sorted { a, b in
                let pa = points[a.line], pb = points[b.line]
                let da = min(hypot(pa[0].x - origin.x, pa[0].y - origin.y), hypot(pa[1].x - origin.x, pa[1].y - origin.y))
                let db = min(hypot(pb[0].x - origin.x, pb[0].y - origin.y), hypot(pb[1].x - origin.x, pb[1].y - origin.y))
                return da < db
            }
            for extra in byDistance.dropFirst(room) {
                dropped.insert(extra.line)
                if let label = extra.label { dropped.insert(label) }
            }
            groups[vertex] = bonds.filter { !dropped.contains($0.line) }
        }

        var result = action
        for (vertex, bonds) in groups where !bonds.isEmpty {
            let origin = skeleton.vertices[vertex]
            let existing = skeleton.neighbors[vertex].map { atan2(skeleton.vertices[$0].y - origin.y, skeleton.vertices[$0].x - origin.x) }
            let directions = spread(count: bonds.count, around: existing)
            // Keep the model's rough intent: pair bonds with directions in angular order.
            let modelAngles = bonds.map { bond -> CGFloat in
                let p = points[bond.line]
                let far = skeleton.nearestVertex(to: p[0], within: attach) == vertex ? p[1] : p[0]
                return atan2(far.y - origin.y, far.x - origin.x)
            }
            let order = bonds.indices.sorted { modelAngles[$0] < modelAngles[$1] }
            let sortedDirections = directions.sorted()
            let modelLengths = bonds.map { bond -> CGFloat in hypot(points[bond.line][1].x - points[bond.line][0].x, points[bond.line][1].y - points[bond.line][0].y) }
            for (rank, b) in order.enumerated() {
                let angle = sortedDirections[rank]
                var length = modelLengths[b]
                if let bondLength = skeleton.bondLength { length = min(max(length, bondLength * 0.55), bondLength * 0.75) }
                let end = CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
                let bond = bonds[b]
                result.shapes[bond.line].points = [normalized(origin, pageSize), normalized(end, pageSize)]
                if let label = bond.label { result.shapes[label].points = [normalized(end, pageSize)] }
            }
        }
        if hydrogenOnly {
            // Exactly one H at the end of each bond; stray or misplaced H's go.
            let size = action.shapes.first { $0.kind == .text }?.size ?? .small
            let bonds = result.shapes.enumerated().filter { $0.element.kind == .line && !dropped.contains($0.offset) }.map(\.element)
            result.shapes = bonds.flatMap { bond in
                [bond, DrawAction.Shape(kind: .text, points: [bond.points[1]], text: "H", size: size)]
            }
            return result
        }
        if !dropped.isEmpty {
            result.shapes = result.shapes.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        }
        return result
    }

    /// `count` directions spread evenly through the largest gap between `existing` bond angles
    /// (all around when there are none).
    static func spread(count: Int, around existing: [CGFloat]) -> [CGFloat] {
        guard count > 0 else { return [] }
        let twoPi = 2 * CGFloat.pi
        guard !existing.isEmpty else {
            return (0..<count).map { -CGFloat.pi / 2 + twoPi * CGFloat($0) / CGFloat(count) }
        }
        let sorted = existing.map { ($0 + twoPi).truncatingRemainder(dividingBy: twoPi) }.sorted()
        var bestStart: CGFloat = sorted[0], bestGap: CGFloat = 0
        for (i, a) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1] : sorted[0] + twoPi
            if next - a > bestGap { bestGap = next - a; bestStart = a }
        }
        return (1...count).map { bestStart + bestGap * CGFloat($0) / CGFloat(count + 1) }
    }

    private static func normalized(_ p: CGPoint, _ size: CGSize) -> NormPoint {
        NormPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
    }
}
