import CoreGraphics

/// Where each molecule of an analysis sits inside a view rect: one uniform scale so bond
/// lengths match across a reaction, reactants "+" … "→" products laid out left to right.
/// Used for drawing and for hit-testing taps, so both always agree.
struct MoleculeLayout: Equatable, Sendable {
    struct Placement: Equatable, Sendable {
        var origin: CGPoint
        var size: CGSize
    }

    enum Glyph: Equatable, Sendable {
        case plus(CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
    }

    var bounds: CGRect
    var scale: CGFloat
    var placements: [Placement]
    var glyphs: [Glyph]

    /// On-screen bond length.
    var bondLength: CGFloat
    static let plusWidth: CGFloat = 26
    static let arrowWidth: CGFloat = 64

    init(analysis: MoleculeAnalysis, in rect: CGRect, maxBondLength: CGFloat = 46) {
        bounds = rect
        let molecules = analysis.molecules
        guard !molecules.isEmpty, rect.width > 1, rect.height > 1 else {
            scale = 1; placements = []; glyphs = []; bondLength = 0
            return
        }
        var gaps: [CGFloat] = []
        for i in 1..<max(molecules.count, 1) {
            gaps.append(analysis.arrowAfter == i ? Self.arrowWidth : Self.plusWidth)
        }
        let gapTotal = gaps.reduce(0, +)
        let widths = molecules.map(\.width).reduce(0, +)
        let heights = molecules.map(\.height).max() ?? 1
        let reference = molecules.first?.bondLength ?? 30
        let fit = min((rect.width - gapTotal) / max(widths, 1), rect.height / max(heights, 1))
        scale = max(0.05, min(fit, maxBondLength / reference))
        bondLength = reference * scale

        let total = widths * scale + gapTotal
        var x = rect.minX + (rect.width - total) / 2
        var placed: [Placement] = []
        var glyphs: [Glyph] = []
        for (i, molecule) in molecules.enumerated() {
            let size = CGSize(width: molecule.width * scale, height: molecule.height * scale)
            placed.append(Placement(origin: CGPoint(x: x, y: rect.midY - size.height / 2), size: size))
            x += size.width
            if i < gaps.count {
                let mid = CGPoint(x: x + gaps[i] / 2, y: rect.midY)
                if analysis.arrowAfter == i + 1 {
                    glyphs.append(.arrow(from: CGPoint(x: x + 10, y: mid.y), to: CGPoint(x: x + gaps[i] - 10, y: mid.y)))
                } else {
                    glyphs.append(.plus(mid))
                }
                x += gaps[i]
            }
        }
        placements = placed
        self.glyphs = glyphs
    }

    /// RDKit drawing coordinates of molecule `m` → view coordinates.
    func point(_ p: CGPoint, molecule m: Int) -> CGPoint {
        let o = placements[m].origin
        return CGPoint(x: o.x + p.x * scale, y: o.y + p.y * scale)
    }

    func transform(molecule m: Int) -> CGAffineTransform {
        let o = placements[m].origin
        return CGAffineTransform(translationX: o.x, y: o.y).scaledBy(x: scale, y: scale)
    }

    enum Hit: Equatable, Sendable {
        case atom(molecule: Int, atom: Int)
        case bond(molecule: Int, bond: Int)
    }

    /// The atom (preferred) or bond under a view point, within a finger-sized radius.
    func hitTest(_ point: CGPoint, analysis: MoleculeAnalysis, slop: CGFloat = 22) -> Hit? {
        var best: (Hit, CGFloat)?
        let atomRadius = max(slop, bondLength * 0.45)
        for (m, molecule) in analysis.molecules.enumerated() where m < placements.count {
            for atom in molecule.atoms {
                let d = distance(point, self.point(atom.point, molecule: m))
                if d <= atomRadius, d < (best?.1 ?? .infinity) { best = (.atom(molecule: m, atom: atom.index), d) }
            }
        }
        if best != nil { return best?.0 }
        for (m, molecule) in analysis.molecules.enumerated() where m < placements.count {
            for bond in molecule.bonds {
                let a = self.point(molecule.atoms[bond.a].point, molecule: m)
                let b = self.point(molecule.atoms[bond.b].point, molecule: m)
                let d = segmentDistance(point, a, b)
                if d <= slop, d < (best?.1 ?? .infinity) { best = (.bond(molecule: m, bond: bond.index), d) }
            }
        }
        return best?.0
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}
