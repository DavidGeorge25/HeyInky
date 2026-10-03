import SwiftUI

/// Draws RDKit's depiction natively (vector, so it stays sharp at any zoom) with soft
/// functional-group highlights, labels, stars and R/S · E/Z tags on top.
struct MoleculeCanvas: View {
    let analysis: MoleculeAnalysis
    let groups: MoleculeGroups
    var selectedKey: String?
    var showLabels = true
    var showStereo = true
    /// Chrome scale (page zoom), for label text and strokes.
    var scale: CGFloat = 1
    var maxBondLength: CGFloat = 46

    @Environment(\.colorScheme) private var colorScheme

    static let starColor = Color(red: 0.98, green: 0.72, blue: 0.10)

    var body: some View {
        Canvas { context, size in
            let layout = MoleculeLayout(analysis: analysis, in: Self.drawingRect(in: size, scale: scale), maxBondLength: maxBondLength * scale)
            draw(in: &context, size: size, layout: layout)
        }
    }

    /// Inset that leaves room for labels around the molecule.
    static func drawingRect(in size: CGSize, scale: CGFloat) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: min(28 * scale, size.width * 0.12), dy: min(24 * scale, size.height * 0.14))
    }

    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { dark ? Color(white: 0.93) : Color(red: 0.12, green: 0.12, blue: 0.15) }
    private var surface: Color { dark ? Color(white: 0.11) : .white }

    private func atomColor(_ rgb: RGB) -> Color {
        if rgb.isBlack { return ink }
        guard dark else { return rgb.color }
        // Lift heteroatom colors so they read on a dark surface.
        return Color(.sRGB, red: rgb.r + (1 - rgb.r) * 0.35, green: rgb.g + (1 - rgb.g) * 0.35, blue: rgb.b + (1 - rgb.b) * 0.35)
    }

    private func labelInk(_ tint: GroupPalette.Tint) -> Color { dark ? tint.fill.color : tint.ink.color }

    private func draw(in context: inout GraphicsContext, size: CGSize, layout: MoleculeLayout) {
        let visible = groups.all.filter { groups.highlighted.contains($0.key) || $0.key == selectedKey }

        // 1. Highlights under the structure; one layer per group so overlaps don't darken.
        for group in visible {
            let selected = group.key == selectedKey
            let dimmed = selectedKey != nil && !selected
            let opacity = (dark ? 0.45 : 0.5) * (selected ? 1.4 : (dimmed ? 0.45 : 1))
            context.drawLayer { layer in
                layer.opacity = min(opacity, 0.9)
                let shading = GraphicsContext.Shading.color(group.tint.fill.color)
                for instance in group.instances where instance.molecule < layout.placements.count {
                    for piece in highlightPieces(instance, layout: layout) { layer.fill(piece, with: shading) }
                }
            }
        }

        // 2. The molecule itself.
        for (m, molecule) in analysis.molecules.enumerated() where m < layout.placements.count {
            let transform = layout.transform(molecule: m)
            for primitive in molecule.primitives {
                let path = primitive.path.applying(transform)
                let color = atomColor(primitive.color)
                switch primitive.kind {
                case .fill:
                    context.fill(path, with: .color(color))
                case .stroke:
                    let width = max(1, primitive.lineWidth * layout.scale * 0.8)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: primitive.dashed ? [width * 1.5, width * 1.5] : []))
                }
            }
        }

        // 3. Reaction glyphs.
        drawGlyphs(in: &context, layout: layout)

        // 4. Tags and labels, placed around everything already drawn.
        var obstacles = MoleculeObstacles(analysis: analysis, layout: layout)
        // The card's formula/name summary sits in the top-left corner.
        obstacles.rects.append(CGRect(x: 0, y: 0, width: min(size.width * 0.6, 220 * scale), height: 26 * scale))
        if showStereo { drawStereo(in: &context, layout: layout, obstacles: &obstacles) }
        let placements = MoleculeLabelPlacer.place(
            groups: groups, selectedKey: selectedKey, showLabels: showLabels,
            analysis: analysis, layout: layout, canvas: CGRect(origin: .zero, size: size), scale: scale, obstacles: obstacles,
            measure: { context.resolve(labelText($0)).measure(in: CGSize(width: 400, height: 100)) }
        )
        for item in placements { drawLabel(item, in: &context) }
    }

    /// Round-capped bond strokes and atom discs, filled one by one (a single combined path
    /// would cancel where the windings overlap).
    private func highlightPieces(_ instance: DisplayGroup.Instance, layout: MoleculeLayout) -> [Path] {
        let molecule = analysis.molecules[instance.molecule]
        var pieces: [Path] = []
        let width = layout.bondLength * 0.42
        for b in instance.bonds where b < molecule.bonds.count {
            let bond = molecule.bonds[b]
            var segment = Path()
            segment.move(to: layout.point(molecule.atoms[bond.a].point, molecule: instance.molecule))
            segment.addLine(to: layout.point(molecule.atoms[bond.b].point, molecule: instance.molecule))
            pieces.append(segment.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round)))
        }
        let radius = layout.bondLength * 0.3
        for a in instance.atoms where a < molecule.atoms.count {
            let p = layout.point(molecule.atoms[a].point, molecule: instance.molecule)
            pieces.append(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)))
        }
        return pieces
    }

    private func drawGlyphs(in context: inout GraphicsContext, layout: MoleculeLayout) {
        let style = StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
        for glyph in layout.glyphs {
            switch glyph {
            case .plus(let p):
                let r = 6 * scale
                var plus = Path()
                plus.move(to: CGPoint(x: p.x - r, y: p.y)); plus.addLine(to: CGPoint(x: p.x + r, y: p.y))
                plus.move(to: CGPoint(x: p.x, y: p.y - r)); plus.addLine(to: CGPoint(x: p.x, y: p.y + r))
                context.stroke(plus, with: .color(ink.opacity(0.7)), style: style)
            case .arrow(let from, let to):
                var arrow = Path()
                arrow.move(to: from); arrow.addLine(to: to)
                arrow.move(to: CGPoint(x: to.x - 8 * scale, y: to.y - 5 * scale)); arrow.addLine(to: to)
                arrow.addLine(to: CGPoint(x: to.x - 8 * scale, y: to.y + 5 * scale))
                context.stroke(arrow, with: .color(ink.opacity(0.75)), style: style)
                if !analysis.agents.isEmpty {
                    let text = Text(analysis.agents.joined(separator: ", "))
                        .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.6))
                    context.draw(text, at: CGPoint(x: (from.x + to.x) / 2, y: from.y - 6 * scale), anchor: .bottom)
                }
            }
        }
    }

    private func drawStereo(in context: inout GraphicsContext, layout: MoleculeLayout, obstacles: inout MoleculeObstacles) {
        let font = Font.system(size: 9 * scale, weight: .semibold, design: .rounded).italic()
        let color = dark ? Color(red: 0.68, green: 0.68, blue: 1.0) : Theme.accent
        func tag(_ label: String, near anchor: CGPoint, preferring direction: CGVector, distance: CGFloat) {
            let text = context.resolve(Text(label).font(font).foregroundStyle(color))
            let size = text.measure(in: CGSize(width: 60, height: 30))
            let rect = obstacles.freeSpot(size: size, around: anchor, preferring: direction, distance: distance, padding: 1.5 * scale)
            obstacles.rects.append(rect)
            context.fill(Path(roundedRect: rect.insetBy(dx: -1.5 * scale, dy: -0.5 * scale), cornerRadius: 3 * scale), with: .color(surface.opacity(0.85)))
            context.draw(text, in: rect)
        }
        for (m, molecule) in analysis.molecules.enumerated() where m < layout.placements.count {
            for center in molecule.stereocenters where center.atom < molecule.atoms.count {
                let p = layout.point(molecule.atoms[center.atom].point, molecule: m)
                let away = Self.awayDirection(atom: center.atom, in: molecule)
                tag("(\(center.label))", near: p, preferring: away, distance: layout.bondLength * 0.42)
            }
            for bond in molecule.stereobonds where bond.a < molecule.atoms.count && bond.b < molecule.atoms.count {
                let a = layout.point(molecule.atoms[bond.a].point, molecule: m)
                let b = layout.point(molecule.atoms[bond.b].point, molecule: m)
                let len = max(hypot(b.x - a.x, b.y - a.y), 1)
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                tag("(\(bond.label))", near: mid, preferring: CGVector(dx: -(b.y - a.y) / len, dy: (b.x - a.x) / len), distance: layout.bondLength * 0.4)
            }
        }
    }

    /// Unit vector pointing away from an atom's bonds (where a tag won't collide with them).
    static func awayDirection(atom: Int, in molecule: MoleculeDepiction) -> CGVector {
        let p = molecule.atoms[atom].point
        var sum = CGVector.zero
        for bond in molecule.bonds where bond.a == atom || bond.b == atom {
            let other = molecule.atoms[bond.a == atom ? bond.b : bond.a].point
            let len = max(hypot(other.x - p.x, other.y - p.y), 0.001)
            sum.dx += (other.x - p.x) / len
            sum.dy += (other.y - p.y) / len
        }
        let len = hypot(sum.dx, sum.dy)
        guard len > 0.2 else { return CGVector(dx: 0.7071, dy: -0.7071) }
        return CGVector(dx: -sum.dx / len, dy: -sum.dy / len)
    }

    private func labelText(_ item: MoleculeLabelPlacer.Item) -> Text {
        let star = item.starred ? Text(Image(systemName: "star.fill")).foregroundStyle(Self.starColor) + Text(item.text.isEmpty ? "" : " ") : Text("")
        return (star + Text(item.text).foregroundStyle(labelInk(item.tint)))
            .font(.system(size: 10 * scale, weight: .semibold, design: .rounded))
    }

    private func drawLabel(_ item: MoleculeLabelPlacer.Item, in context: inout GraphicsContext) {
        let rect = item.rect
        if item.text.isEmpty {
            // A bare star (labels hidden).
            var symbol = context.resolve(Image(systemName: "star.fill"))
            symbol.shading = .color(Self.starColor)
            var star = context
            star.addFilter(.shadow(color: .black.opacity(0.18), radius: 1.5 * scale, y: 0.5 * scale))
            star.draw(symbol, in: rect)
            return
        }
        let capsule = Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .continuous)
        context.fill(capsule, with: .color(surface))
        context.fill(capsule, with: .color(item.tint.fill.color.opacity(dark ? (item.selected ? 0.32 : 0.16) : (item.selected ? 0.55 : 0.28))))
        context.stroke(capsule, with: .color(labelInk(item.tint).opacity(item.selected ? 0.9 : 0.35)), lineWidth: (item.selected ? 1.2 : 0.7) * scale)
        context.draw(labelText(item), at: CGPoint(x: rect.midX, y: rect.midY))
    }
}

/// Things tags and labels must not cover: atom-label glyphs, bonds, other molecules and
/// reaction glyphs, plus whatever has been placed so far.
struct MoleculeObstacles {
    var rects: [CGRect] = []
    var segments: [(CGPoint, CGPoint)] = []
    var atoms: [CGPoint] = []
    /// Molecule bounding boxes (labels may sit near their own molecule, not over others).
    var molecules: [CGRect] = []

    init(analysis: MoleculeAnalysis, layout: MoleculeLayout) {
        for (m, molecule) in analysis.molecules.enumerated() where m < layout.placements.count {
            let transform = layout.transform(molecule: m)
            for primitive in molecule.primitives where primitive.kind == .fill && !primitive.atoms.isEmpty && primitive.bond == nil {
                rects.append(primitive.path.applying(transform).boundingRect)
            }
            for bond in molecule.bonds {
                segments.append((layout.point(molecule.atoms[bond.a].point, molecule: m), layout.point(molecule.atoms[bond.b].point, molecule: m)))
            }
            atoms += molecule.atoms.map { layout.point($0.point, molecule: m) }
            let placement = layout.placements[m]
            molecules.append(CGRect(origin: placement.origin, size: placement.size))
        }
        for glyph in layout.glyphs {
            switch glyph {
            case .plus(let p): rects.append(CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
            case .arrow(let from, let to): rects.append(CGRect(x: from.x, y: from.y - 18, width: to.x - from.x, height: 26))
            }
        }
    }

    /// Overlap cost of a candidate rect (0 = free).
    func cost(_ rect: CGRect, ownMolecule: Int? = nil) -> CGFloat {
        var cost: CGFloat = 0
        for r in rects where r.intersects(rect) { cost += 10 }
        for (a, b) in segments where Self.segment(a, b, intersects: rect) { cost += 4 }
        for (i, r) in molecules.enumerated() where i != ownMolecule && r.insetBy(dx: 4, dy: 4).intersects(rect) { cost += 12 }
        return cost
    }

    /// The best rect of `size` around `anchor`, trying directions fanned out from `preferring`.
    func freeSpot(size: CGSize, around anchor: CGPoint, preferring direction: CGVector, distance: CGFloat, padding: CGFloat) -> CGRect {
        var best: (CGRect, CGFloat)?
        for angle in [0, 30, -30, 60, -60, 95, -95, 135, -135, 180] as [CGFloat] {
            let rad = angle * .pi / 180
            let d = CGVector(dx: direction.dx * cos(rad) - direction.dy * sin(rad), dy: direction.dx * sin(rad) + direction.dy * cos(rad))
            let reach = distance + abs(d.dx) * size.width / 2 + abs(d.dy) * size.height / 2
            let rect = CGRect(x: anchor.x + d.dx * reach - size.width / 2, y: anchor.y + d.dy * reach - size.height / 2, width: size.width, height: size.height)
            let c = cost(rect.insetBy(dx: -padding, dy: -padding)) + abs(angle) / 120
            if c < (best?.1 ?? .infinity) { best = (rect, c) }
            if c < 0.01 { break }
        }
        return best!.0
    }

    static func segment(_ a: CGPoint, _ b: CGPoint, intersects rect: CGRect) -> Bool {
        // Shorten the segment a little so tags may touch the atom they describe.
        for t in stride(from: 0.15 as CGFloat, through: 0.85, by: 0.1) {
            if rect.contains(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) { return true }
        }
        return false
    }
}

/// Places one small label per highlighted group instance just outside the molecule, nudging
/// around atoms, bonds and other labels; starred instances get a star (in the label, or
/// alone when labels are off).
enum MoleculeLabelPlacer {
    struct Item: Equatable {
        var key: String
        var text: String
        var tint: GroupPalette.Tint
        var rect: CGRect
        var starred: Bool
        var selected: Bool
    }

    static func place(groups: MoleculeGroups, selectedKey: String?, showLabels: Bool,
                      analysis: MoleculeAnalysis, layout: MoleculeLayout, canvas: CGRect, scale: CGFloat,
                      obstacles: MoleculeObstacles, measure: (Item) -> CGSize) -> [Item] {
        var obstacles = obstacles
        var items: [Item] = []
        // Selected group first so it gets the best spot.
        let ordered = groups.all.sorted { ($0.key == selectedKey ? 0 : 1) < ($1.key == selectedKey ? 0 : 1) }
        for group in ordered {
            let starred = groups.starred.contains(group.key)
            let labeled = showLabels && (groups.highlighted.contains(group.key) || group.key == selectedKey)
            guard labeled || starred else { continue }
            for instance in group.instances where instance.molecule < layout.placements.count {
                let molecule = analysis.molecules[instance.molecule]
                let points = instance.atoms.filter { $0 < molecule.atoms.count }.map { layout.point(molecule.atoms[$0].point, molecule: instance.molecule) }
                guard !points.isEmpty else { continue }
                let centroid = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
                // Point away from the rest of the molecule (its atoms' mean), so labels sit outside.
                let others = molecule.atoms.filter { !instance.atoms.contains($0.index) }.map { layout.point($0.point, molecule: instance.molecule) }
                let pivot = others.isEmpty
                    ? CGPoint(x: layout.placements[instance.molecule].origin.x + layout.placements[instance.molecule].size.width / 2, y: centroid.y + 1)
                    : CGPoint(x: others.map(\.x).reduce(0, +) / CGFloat(others.count), y: others.map(\.y).reduce(0, +) / CGFloat(others.count))
                var direction = CGVector(dx: centroid.x - pivot.x, dy: centroid.y - pivot.y)
                let len = hypot(direction.dx, direction.dy)
                direction = len > 1 ? CGVector(dx: direction.dx / len, dy: direction.dy / len) : CGVector(dx: 0, dy: -1)

                var item = Item(key: group.key, text: labeled ? group.shortName : "", tint: group.tint, rect: .zero, starred: starred, selected: group.key == selectedKey)
                let size: CGSize
                if labeled {
                    let text = measure(item)
                    size = CGSize(width: text.width + 12 * scale, height: text.height + 5 * scale)
                } else {
                    size = CGSize(width: 15 * scale, height: 15 * scale)
                }
                let reach = points.map { hypot($0.x - centroid.x, $0.y - centroid.y) }.max() ?? 0
                let base = reach + layout.bondLength * (labeled ? 0.4 : 0.3)

                var best: (CGRect, CGFloat)?
                search: for push in [0, 0.6, 1.3] as [CGFloat] {
                    for angle in [0, 30, -30, 60, -60, 95, -95, 140, -140, 180] as [CGFloat] {
                        let rad = angle * .pi / 180
                        let d = CGVector(dx: direction.dx * cos(rad) - direction.dy * sin(rad), dy: direction.dx * sin(rad) + direction.dy * cos(rad))
                        let distance = base + push * layout.bondLength + abs(d.dx) * size.width / 2 + abs(d.dy) * size.height / 2
                        var rect = CGRect(x: centroid.x + d.dx * distance - size.width / 2, y: centroid.y + d.dy * distance - size.height / 2, width: size.width, height: size.height)
                        rect.origin.x = min(max(rect.minX, canvas.minX + 2), canvas.maxX - size.width - 2)
                        rect.origin.y = min(max(rect.minY, canvas.minY + 2), canvas.maxY - size.height - 2)
                        let padded = rect.insetBy(dx: -3 * scale, dy: -2 * scale)
                        let atomHits = obstacles.atoms.filter { padded.insetBy(dx: -layout.bondLength * 0.1, dy: -layout.bondLength * 0.1).contains($0) }.count
                        let cost = obstacles.cost(padded, ownMolecule: instance.molecule) + CGFloat(atomHits) * 3 + abs(angle) / 100 + push * 0.8
                        if cost < (best?.1 ?? .infinity) { best = (rect, cost) }
                        if cost < 0.35 { break search }
                    }
                }
                guard let best else { continue }
                item.rect = best.0
                obstacles.rects.append(best.0)
                items.append(item)
            }
        }
        return items
    }
}
