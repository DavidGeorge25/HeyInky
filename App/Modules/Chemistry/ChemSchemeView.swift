import SwiftUI

/// Layout of a chemistry scheme in design units (1 unit = 1 page point at `designBond`): every
/// structure scaled to the same bond length, laid out left to right with connectors, wrapped
/// into rows when it would be wider than the page allows. Deterministic, so placing the figure
/// (at apply time) and drawing it (any zoom) agree.
struct ChemSchemeLayout: Equatable, Sendable {
    static let designBond: CGFloat = 32
    /// Room around each structure for lone pairs and curved arrows that bow outside it.
    static let stepPad: CGFloat = 20
    static let gapPlus: CGFloat = 34
    static let gapResonance: CGFloat = 58
    static let gapReaction: CGFloat = 74
    static let gapNone: CGFloat = 22
    static let titleHeight: CGFloat = 30
    static let captionHeight: CGFloat = 24
    static let stepLabelHeight: CGFloat = 20
    static let rowGap: CGFloat = 26

    struct Placed: Equatable, Sendable {
        var step: Int
        var origin: CGPoint
        var scale: CGFloat
        var size: CGSize
    }

    struct Connector: Equatable, Sendable {
        var kind: InsertChemSchemeAction.ConnectorKind
        var from: CGPoint
        var to: CGPoint
        var above: String?
        var below: String?
    }

    var size: CGSize
    var steps: [Placed]
    var connectors: [Connector]
    var titleOrigin: CGPoint?
    var captionOrigin: CGPoint?

    init(analysis: SchemeAnalysis, action: InsertChemSchemeAction, maxWidth: CGFloat) {
        let depictions = analysis.steps.map(\.depiction)
        func scale(_ d: MoleculeDepiction) -> CGFloat {
            let drawn = (d.drawnBondLength ?? d.bondLength)
            return Self.designBond / max(drawn, 1)
        }
        func gap(_ i: Int) -> CGFloat {
            guard i < action.connectors.count else { return Self.gapPlus }
            let c = action.connectors[i]
            let base: CGFloat = switch c.kind {
            case .plus: Self.gapPlus
            case .resonance: Self.gapResonance
            case .reaction, .equilibrium: Self.gapReaction
            case .none: Self.gapNone
            }
            let text = max((c.above ?? "").count, (c.below ?? "").count)
            return max(base, CGFloat(text) * 7 + 24)
        }
        // Rows: greedy wrap at maxWidth.
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        for (i, d) in depictions.enumerated() {
            let w = (d.map { $0.width * scale($0) } ?? 60) + 2 * Self.stepPad
            let extra = rows[rows.count - 1].isEmpty ? 0 : gap(i - 1)
            if !rows[rows.count - 1].isEmpty && rowWidth + extra + w > maxWidth {
                rows.append([i])
                rowWidth = w
            } else {
                rows[rows.count - 1].append(i)
                rowWidth += extra + w
            }
        }
        var y: CGFloat = 0
        titleOrigin = nil
        if action.title?.isEmpty == false {
            titleOrigin = CGPoint(x: 0, y: 0)
            y += Self.titleHeight
        }
        var placed: [Placed] = []
        var connectors: [Connector] = []
        var widest: CGFloat = 0
        let hasStepLabels = action.steps.contains { $0.label?.isEmpty == false }
        for (r, row) in rows.enumerated() {
            let heights = row.map { i in (depictions[i].map { $0.height * scale($0) } ?? 50) + 2 * Self.stepPad }
            let rowHeight = heights.max() ?? 50
            var x: CGFloat = 0
            for (k, i) in row.enumerated() {
                if k > 0 {
                    let g = gap(i - 1)
                    let mid = y + rowHeight / 2
                    let c = i - 1 < action.connectors.count ? action.connectors[i - 1] : .init(kind: .plus, above: nil, below: nil)
                    connectors.append(Connector(kind: c.kind, from: CGPoint(x: x + 10, y: mid), to: CGPoint(x: x + g - 10, y: mid), above: c.above, below: c.below))
                    x += g
                }
                let s = depictions[i].map(scale) ?? 1
                let size = depictions[i].map { CGSize(width: $0.width * s, height: $0.height * s) } ?? CGSize(width: 60, height: 50)
                placed.append(Placed(step: i, origin: CGPoint(x: x + Self.stepPad, y: y + (rowHeight - size.height) / 2), scale: s, size: size))
                x += size.width + 2 * Self.stepPad
            }
            // A row that continues the scheme starts with its connector on the right of the previous row.
            if r + 1 < rows.count, let next = rows[r + 1].first, next - 1 < action.connectors.count {
                let c = action.connectors[next - 1]
                let mid = y + rowHeight / 2
                connectors.append(Connector(kind: c.kind, from: CGPoint(x: x + 10, y: mid), to: CGPoint(x: x + gap(next - 1) - 10, y: mid), above: c.above, below: c.below))
                x += gap(next - 1)
            }
            widest = max(widest, x)
            y += rowHeight + (hasStepLabels ? Self.stepLabelHeight : 0) + (r + 1 < rows.count ? Self.rowGap : 0)
        }
        captionOrigin = nil
        if action.caption?.isEmpty == false {
            y += 6
            captionOrigin = CGPoint(x: 0, y: y)
            y += Self.captionHeight
        }
        size = CGSize(width: max(widest, 80), height: max(y, 40))
        steps = placed
        self.connectors = connectors
    }

    /// The natural width of the whole scheme on one row, for choosing a page width to wrap at.
    static func preferredMaxWidth(pageWidth: CGFloat) -> CGFloat { pageWidth * 0.86 }

    func point(_ p: CGPoint, step: Int) -> CGPoint {
        guard let placed = steps.first(where: { $0.step == step }) else { return p }
        return CGPoint(x: placed.origin.x + p.x * placed.scale, y: placed.origin.y + p.y * placed.scale)
    }
}

/// Draws an `insertChemScheme` figure: RDKit structures (vector), connectors with reagents, lone
/// pairs, highlights and red curved electron arrows anchored on mapped atoms.
struct ChemSchemeView: View {
    let action: InsertChemSchemeAction
    var pageWidth: CGFloat = 816

    @State private var analysis: SchemeAnalysis?
    @State private var failed: String?

    var body: some View {
        Group {
            if let analysis {
                Canvas { context, size in
                    let layout = ChemSchemeLayout(analysis: analysis, action: action, maxWidth: ChemSchemeLayout.preferredMaxWidth(pageWidth: pageWidth))
                    let fit = min(size.width / layout.size.width, size.height / layout.size.height)
                    let offset = CGPoint(x: (size.width - layout.size.width * fit) / 2, y: (size.height - layout.size.height * fit) / 2)
                    context.translateBy(x: offset.x, y: offset.y)
                    context.scaleBy(x: fit, y: fit)
                    ChemSchemeRenderer.draw(analysis: analysis, action: action, layout: layout, in: &context)
                }
                .accessibilityElement()
                .accessibilityLabel(Self.accessibilityText(action))
            } else if let failed {
                Text(failed).font(.caption).foregroundStyle(.secondary).padding()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityIdentifier("inky.figure.chemScheme")
        .task(id: action.steps.map(\.smiles)) {
            do {
                let result = try await MoleculeEngine.shared.scheme(steps: action.steps.map(\.smiles))
                if result.steps.contains(where: { !$0.ok }) {
                    failed = result.error ?? "A structure couldn't be drawn."
                }
                analysis = result
            } catch {
                failed = error.localizedDescription
            }
        }
    }

    static func accessibilityText(_ action: InsertChemSchemeAction) -> String {
        let kinds = action.connectors.map(\.kind.rawValue)
        return "Chemistry figure" + (action.title.map { ": \($0)" } ?? "") + ", \(action.steps.count) structures" + (kinds.isEmpty ? "" : " (\(Set(kinds).sorted().joined(separator: ", ")))")
    }
}

enum ChemSchemeRenderer {
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.15)
    static let arrowRed = Color(red: 0.88, green: 0.24, blue: 0.27)

    static func draw(analysis: SchemeAnalysis, action: InsertChemSchemeAction, layout: ChemSchemeLayout, in context: inout GraphicsContext) {
        // Title.
        if let title = action.title, let origin = layout.titleOrigin {
            context.draw(Text(title).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundColor(ink),
                         at: CGPoint(x: origin.x, y: origin.y + 4), anchor: .topLeading)
        }

        for placed in layout.steps {
            guard placed.step < analysis.steps.count, let d = analysis.steps[placed.step].depiction else { continue }
            let maps = analysis.steps[placed.step].maps
            let transform = CGAffineTransform(translationX: placed.origin.x, y: placed.origin.y).scaledBy(x: placed.scale, y: placed.scale)

            // Highlights under the structure.
            for h in action.highlights where h.step == placed.step {
                let atoms = Set(h.atoms.compactMap { maps[$0] })
                let color = highlightColor(h.color).opacity(0.45)
                for bond in d.bonds where atoms.contains(bond.a) && atoms.contains(bond.b) {
                    var p = Path()
                    p.move(to: d.atoms[bond.a].point.applying(transform))
                    p.addLine(to: d.atoms[bond.b].point.applying(transform))
                    context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: ChemSchemeLayout.designBond * 0.42, lineCap: .round))
                }
                for a in atoms {
                    let c = d.atoms[a].point.applying(transform)
                    let r = ChemSchemeLayout.designBond * 0.3
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
                }
            }

            // The structure.
            for primitive in d.primitives {
                let path = primitive.path.applying(transform)
                let color = primitive.color.isBlack ? ink : primitive.color.color
                switch primitive.kind {
                case .fill:
                    context.fill(path, with: .color(color))
                case .stroke:
                    let width = max(1, primitive.lineWidth * placed.scale * 0.8)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: primitive.dashed ? [width * 1.5, width * 1.5] : []))
                }
            }

            // Lone pairs: two dots on the atom's open side.
            for lp in action.lonePairs where lp.step == placed.step {
                guard let i = maps[lp.atom], i < d.atoms.count else { continue }
                let dir = MoleculeCanvas.awayDirection(atom: i, in: d)
                let c = d.atoms[i].point.applying(transform)
                let center = CGPoint(x: c.x + dir.dx * 11, y: c.y + dir.dy * 11)
                let n = CGPoint(x: -dir.dy, y: dir.dx)
                for s in [-1.0, 1.0] {
                    let p = CGPoint(x: center.x + n.x * 3.2 * s, y: center.y + n.y * 3.2 * s)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 1.7, y: p.y - 1.7, width: 3.4, height: 3.4)), with: .color(ink))
                }
            }

            // Electron-pushing arrows.
            let centroid: CGPoint = {
                let pts = d.atoms.map { $0.point.applying(transform) }
                return CGPoint(x: pts.reduce(0) { $0 + $1.x } / CGFloat(max(1, pts.count)), y: pts.reduce(0) { $0 + $1.y } / CGFloat(max(1, pts.count)))
            }()
            for arrow in action.arrows where arrow.step == placed.step {
                guard let from = endpoint(arrow.from, d: d, maps: maps, transform: transform, asSource: true),
                      let to = endpoint(arrow.to, d: d, maps: maps, transform: transform, asSource: false) else { continue }
                drawCurvedArrow(from: from, to: to, centroid: centroid, fishhook: arrow.kind == .fishhook, in: &context)
            }

            // Step label.
            if let label = action.steps[safe: placed.step]?.label, !label.isEmpty {
                context.draw(Text(label).font(.system(size: 12, design: .rounded)).foregroundColor(ink.opacity(0.7)),
                             at: CGPoint(x: placed.origin.x + placed.size.width / 2, y: placed.origin.y + placed.size.height + 4), anchor: .top)
            }
        }

        // Connectors.
        for c in layout.connectors { drawConnector(c, in: &context) }

        if let caption = action.caption, let origin = layout.captionOrigin {
            context.draw(Text(caption).font(.system(size: 13, design: .rounded)).foregroundColor(ink.opacity(0.75)),
                         at: CGPoint(x: origin.x, y: origin.y), anchor: .topLeading)
        }
    }

    static func endpoint(_ ref: String, d: MoleculeDepiction, maps: [String: Int], transform: CGAffineTransform, asSource: Bool) -> CGPoint? {
        let parts = ref.split(whereSeparator: { $0 == "-" || $0 == "=" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 {
            guard let a = maps[parts[0]], let b = maps[parts[1]], a < d.atoms.count, b < d.atoms.count else { return nil }
            let pa = d.atoms[a].point.applying(transform), pb = d.atoms[b].point.applying(transform)
            return CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
        }
        guard let first = parts.first, let i = maps[first], i < d.atoms.count else { return nil }
        let c = d.atoms[i].point.applying(transform)
        guard asSource else { return c }
        let dir = MoleculeCanvas.awayDirection(atom: i, in: d)
        return CGPoint(x: c.x + dir.dx * 11, y: c.y + dir.dy * 11)
    }

    static func drawCurvedArrow(from: CGPoint, to rawTo: CGPoint, centroid: CGPoint, fishhook: Bool, in context: inout GraphicsContext) {
        let mid = CGPoint(x: (from.x + rawTo.x) / 2, y: (from.y + rawTo.y) / 2)
        let d = CGPoint(x: rawTo.x - from.x, y: rawTo.y - from.y)
        let dist = max(hypot(d.x, d.y), 1)
        var n = CGPoint(x: -d.y / dist, y: d.x / dist)
        if (mid.x - centroid.x) * n.x + (mid.y - centroid.y) * n.y < 0 { n = CGPoint(x: -n.x, y: -n.y) }
        let bow = max(dist * 0.45, ChemSchemeLayout.designBond * 0.5)
        let control = CGPoint(x: mid.x + n.x * bow, y: mid.y + n.y * bow)
        let back = CGPoint(x: rawTo.x - control.x, y: rawTo.y - control.y)
        let bl = max(hypot(back.x, back.y), 1)
        let u = CGPoint(x: back.x / bl, y: back.y / bl)
        let to = CGPoint(x: rawTo.x - u.x * 4, y: rawTo.y - u.y * 4)
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)
        context.stroke(path, with: .color(arrowRed), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        let head: CGFloat = 7
        var tip = Path()
        let outer: CGFloat = (n.x * -u.y + n.y * u.x) > 0 ? 1 : -1
        let sides: [CGFloat] = fishhook ? [outer] : [1, -1]
        tip.move(to: to)
        for side in sides {
            let a = atan2(u.y, u.x) + .pi + side * 0.42
            tip.addLine(to: CGPoint(x: to.x + cos(a) * head, y: to.y + sin(a) * head))
            tip.move(to: to)
        }
        if fishhook {
            context.stroke(tip, with: .color(arrowRed), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        } else {
            var filled = Path()
            let a1 = atan2(u.y, u.x) + .pi + 0.42, a2 = atan2(u.y, u.x) + .pi - 0.42
            filled.move(to: CGPoint(x: to.x + u.x * 1.5, y: to.y + u.y * 1.5))
            filled.addLine(to: CGPoint(x: to.x + cos(a1) * head, y: to.y + sin(a1) * head))
            filled.addLine(to: CGPoint(x: to.x + cos(a2) * head, y: to.y + sin(a2) * head))
            filled.closeSubpath()
            context.fill(filled, with: .color(arrowRed))
        }
    }

    static func drawConnector(_ c: ChemSchemeLayout.Connector, in context: inout GraphicsContext) {
        let style = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        let mid = CGPoint(x: (c.from.x + c.to.x) / 2, y: c.from.y)
        func head(_ tip: CGPoint, pointingRight: Bool, half: Int = 0) -> Path {
            var p = Path()
            let dx: CGFloat = pointingRight ? -7 : 7
            if half >= 0 { p.move(to: tip); p.addLine(to: CGPoint(x: tip.x + dx, y: tip.y - 4)) }
            if half <= 0 { p.move(to: tip); p.addLine(to: CGPoint(x: tip.x + dx, y: tip.y + 4)) }
            return p
        }
        switch c.kind {
        case .plus:
            var p = Path()
            p.move(to: CGPoint(x: mid.x - 6, y: mid.y)); p.addLine(to: CGPoint(x: mid.x + 6, y: mid.y))
            p.move(to: CGPoint(x: mid.x, y: mid.y - 6)); p.addLine(to: CGPoint(x: mid.x, y: mid.y + 6))
            context.stroke(p, with: .color(ink), style: style)
        case .none:
            break
        case .reaction:
            var p = Path()
            p.move(to: c.from); p.addLine(to: c.to)
            p.addPath(head(c.to, pointingRight: true))
            context.stroke(p, with: .color(ink), style: style)
        case .resonance:
            var p = Path()
            p.move(to: c.from); p.addLine(to: c.to)
            p.addPath(head(c.to, pointingRight: true))
            p.addPath(head(c.from, pointingRight: false))
            context.stroke(p, with: .color(ink), style: style)
        case .equilibrium:
            var p = Path()
            let top = c.from.y - 3, bottom = c.from.y + 3
            p.move(to: CGPoint(x: c.from.x, y: top)); p.addLine(to: CGPoint(x: c.to.x, y: top))
            p.addPath(head(CGPoint(x: c.to.x, y: top), pointingRight: true, half: 1))
            p.move(to: CGPoint(x: c.to.x, y: bottom)); p.addLine(to: CGPoint(x: c.from.x, y: bottom))
            p.addPath(head(CGPoint(x: c.from.x, y: bottom), pointingRight: false, half: -1))
            context.stroke(p, with: .color(ink), style: style)
        }
        let font = Font.system(size: 11, design: .rounded)
        if let above = c.above, !above.isEmpty {
            context.draw(Text(above).font(font).foregroundColor(ink.opacity(0.8)), at: CGPoint(x: mid.x, y: mid.y - 7), anchor: .bottom)
        }
        if let below = c.below, !below.isEmpty {
            context.draw(Text(below).font(font).foregroundColor(ink.opacity(0.8)), at: CGPoint(x: mid.x, y: mid.y + 7), anchor: .top)
        }
    }

    static func highlightColor(_ c: HighlightColor) -> Color {
        switch c {
        case .yellow: Color(red: 1.0, green: 0.86, blue: 0.2)
        case .green: Color(red: 0.45, green: 0.86, blue: 0.5)
        case .blue: Color(red: 0.45, green: 0.72, blue: 1.0)
        case .pink: Color(red: 1.0, green: 0.55, blue: 0.75)
        case .orange: Color(red: 1.0, green: 0.65, blue: 0.3)
        }
    }
}
