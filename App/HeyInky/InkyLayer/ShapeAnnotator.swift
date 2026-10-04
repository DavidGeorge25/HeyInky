import CoreGraphics
import Foundation

/// Compiles `annotateShape` into exact ink on a shape found on the page: free-body-diagram forces
/// (normal is truly perpendicular to the surface the object rests on, weight straight down),
/// angle arcs and right-angle squares inside vertices, side labels outside edges, tick marks.
enum ShapeAnnotator {
    struct Output {
        var actions: [InkyAction] = []
        var problems: [String] = []
    }

    /// - Parameter avoid: page content (text, ink) labels must not cover, normalized.
    static func compile(_ action: AnnotateShapeAction, shape: PageShape, pageSize: CGSize, avoid: [NormRect] = []) -> Output {
        var out = Output()
        var blocked = avoid.map { $0.cgRect(in: pageSize) }
        /// Slides a label outward along `d` until it covers no page text or earlier label.
        func clear(_ at: CGPoint, size: CGSize, along d: CGPoint) -> CGPoint {
            var p = at
            for _ in 0..<6 {
                let r = CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height).insetBy(dx: -2, dy: -2)
                if !blocked.contains(where: { $0.intersects(r) }) { break }
                p = CGPoint(x: p.x + d.x * size.height * 0.8, y: p.y + d.y * size.height * 0.8)
            }
            blocked.append(CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height))
            return p
        }
        let pts = shape.vertices.map { $0.cgPoint(in: pageSize) }
        let center = shape.center.cgPoint(in: pageSize)
        let size: CGFloat = {
            if shape.kind == .circle { return CGFloat(shape.radius) * 2 }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        }()
        func norm(_ p: CGPoint) -> NormPoint { NormPoint(x: min(max(p.x / pageSize.width, 0), 1), y: min(max(p.y / pageSize.height, 0), 1)) }
        func unit(_ v: CGPoint) -> CGPoint { let l = max(hypot(v.x, v.y), 0.0001); return CGPoint(x: v.x / l, y: v.y / l) }

        // The surface the shape rests on: up-slope direction and outward normal.
        var contactPoint: CGPoint?
        var upSlope = CGPoint(x: 1, y: 0), normal = CGPoint(x: 0, y: -1)
        if let contact = shape.contacts.first, pts.count > contact.edge {
            let p1 = pts[contact.edge], p2 = pts[(contact.edge + 1) % pts.count]
            contactPoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            var u = unit(CGPoint(x: p2.x - p1.x, y: p2.y - p1.y))
            if u.y > 0.0001 || (abs(u.y) <= 0.0001 && u.x < 0) { u = CGPoint(x: -u.x, y: -u.y) }
            upSlope = u
            var n = CGPoint(x: -u.y, y: u.x)
            if let cp = contactPoint, (center.x - cp.x) * n.x + (center.y - cp.y) * n.y < 0 { n = CGPoint(x: -n.x, y: -n.y) }
            normal = n
        }

        // 1. Vectors.
        var byColor: [DrawAction.Color: [DrawAction.Shape]] = [:]
        let unitLength = min(max(size * 0.9, 40), 130)
        for v in action.vectors {
            let origin: CGPoint
            switch v.from.lowercased() {
            case "center": origin = center
            case "contact": origin = contactPoint ?? center
            default:
                guard let i = shape.vertexIndex(v.from), i < pts.count else { out.problems.append("\(shape.id) has no vertex \(v.from)"); continue }
                origin = pts[i]
            }
            let d: CGPoint
            switch v.direction {
            case .down: d = CGPoint(x: 0, y: 1)
            case .up: d = CGPoint(x: 0, y: -1)
            case .left: d = CGPoint(x: -1, y: 0)
            case .right: d = CGPoint(x: 1, y: 0)
            case .normal: d = normal
            case .intoSurface: d = CGPoint(x: -normal.x, y: -normal.y)
            case .upSlope: d = upSlope
            case .downSlope: d = CGPoint(x: -upSlope.x, y: -upSlope.y)
            case .angle:
                let a = (v.angle ?? 0) * .pi / 180
                d = CGPoint(x: cos(a), y: -sin(a))
            }
            let factor: CGFloat = switch v.length { case .short: 0.55; case .medium: 0.85; case .long: 1.2 }
            let length = unitLength * factor
            let tip = CGPoint(x: origin.x + d.x * length, y: origin.y + d.y * length)
            var shapes: [DrawAction.Shape] = [.init(kind: .arrow, points: [norm(origin), norm(tip)], text: nil, size: .medium)]
            let label = v.label.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty {
                let (textSize, _) = DrawInk.measure(label, size: .small, pageSize: pageSize)
                let reach = abs(d.x) * textSize.width / 2 + abs(d.y) * textSize.height / 2 + 6
                let at = clear(CGPoint(x: tip.x + d.x * reach, y: tip.y + d.y * reach), size: textSize, along: d)
                let point = DrawInk.isShortLabel(label) ? at : CGPoint(x: at.x - textSize.width / 2, y: at.y - textSize.height / 2)
                shapes.append(.init(kind: .text, points: [norm(point)], text: label, size: .small))
            }
            byColor[v.color, default: []] += shapes
        }
        for (color, shapes) in byColor.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            out.actions.append(.draw(DrawAction(ink: .pen, color: color, shapes: shapes, caption: "forces on \(shape.id)")))
        }

        // 2. Geometry marks.
        var marks: [DrawAction.Shape] = []
        if pts.count >= 3 {
            for mark in action.angleMarks {
                guard let k = shape.vertexIndex(mark.vertex), k < pts.count else { continue }
                let v = pts[k], a = pts[(k - 1 + pts.count) % pts.count], b = pts[(k + 1) % pts.count]
                let ua = unit(CGPoint(x: a.x - v.x, y: a.y - v.y)), ub = unit(CGPoint(x: b.x - v.x, y: b.y - v.y))
                let shortest = min(hypot(a.x - v.x, a.y - v.y), hypot(b.x - v.x, b.y - v.y))
                let r = min(max(shortest * 0.22, 14), 40)
                var bisector = unit(CGPoint(x: ua.x + ub.x, y: ua.y + ub.y))
                // The bisector must point into the shape.
                if (center.x - v.x) * bisector.x + (center.y - v.y) * bisector.y < 0 { bisector = CGPoint(x: -bisector.x, y: -bisector.y) }
                if mark.right {
                    let s = r * 0.6
                    marks.append(.init(kind: .polyline, points: [
                        norm(CGPoint(x: v.x + ua.x * s, y: v.y + ua.y * s)),
                        norm(CGPoint(x: v.x + (ua.x + ub.x) * s, y: v.y + (ua.y + ub.y) * s)),
                        norm(CGPoint(x: v.x + ub.x * s, y: v.y + ub.y * s)),
                    ], text: nil, size: .small))
                } else {
                    // Arc from edge a to edge b through the bisector side.
                    let start = atan2(ua.y, ua.x), end = atan2(ub.y, ub.x)
                    var sweep = Geometry2D.normalize(end - start)
                    let mid = start + sweep / 2
                    if cos(mid) * bisector.x + sin(mid) * bisector.y < 0 { sweep = sweep > 0 ? sweep - 2 * .pi : sweep + 2 * .pi }
                    let arc = (0...16).map { i -> NormPoint in
                        let t = start + sweep * CGFloat(i) / 16
                        return norm(CGPoint(x: v.x + cos(t) * r, y: v.y + sin(t) * r))
                    }
                    marks.append(.init(kind: .polyline, points: arc, text: nil, size: .small))
                }
                if let label = mark.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
                    let (textSize, _) = DrawInk.measure(label, size: .small, pageSize: pageSize)
                    let reach = r + 6 + max(textSize.width, textSize.height) * 0.55
                    let at = clear(CGPoint(x: v.x + bisector.x * reach, y: v.y + bisector.y * reach), size: textSize, along: bisector)
                    let point = DrawInk.isShortLabel(label) ? at : CGPoint(x: at.x - textSize.width / 2, y: at.y - textSize.height / 2)
                    marks.append(.init(kind: .text, points: [norm(point)], text: label, size: .small))
                }
            }
            for side in action.sideLabels {
                guard let k = shape.edgeIndex(side.edge), k < pts.count else { continue }
                let p1 = pts[k], p2 = pts[(k + 1) % pts.count]
                let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                let u = unit(CGPoint(x: p2.x - p1.x, y: p2.y - p1.y))
                var n = CGPoint(x: -u.y, y: u.x)
                if (center.x - mid.x) * n.x + (center.y - mid.y) * n.y > 0 { n = CGPoint(x: -n.x, y: -n.y) }
                let (textSize, _) = DrawInk.measure(side.text, size: .small, pageSize: pageSize)
                let reach = abs(n.x) * textSize.width / 2 + abs(n.y) * textSize.height / 2 + 8
                let at = clear(CGPoint(x: mid.x + n.x * reach, y: mid.y + n.y * reach), size: textSize, along: n)
                let point = DrawInk.isShortLabel(side.text) ? at : CGPoint(x: at.x - textSize.width / 2, y: at.y - textSize.height / 2)
                marks.append(.init(kind: .text, points: [norm(point)], text: side.text, size: .small))
            }
            for tick in action.ticks {
                guard let k = shape.edgeIndex(tick.edge), k < pts.count else { continue }
                let p1 = pts[k], p2 = pts[(k + 1) % pts.count]
                let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                let u = unit(CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)), n = CGPoint(x: -u.y, y: u.x)
                let count = min(max(tick.count, 1), 3)
                for j in 0..<count {
                    let offset = (CGFloat(j) - CGFloat(count - 1) / 2) * 5
                    let c = CGPoint(x: mid.x + u.x * offset, y: mid.y + u.y * offset)
                    marks.append(.init(kind: .line, points: [norm(CGPoint(x: c.x - n.x * 6, y: c.y - n.y * 6)), norm(CGPoint(x: c.x + n.x * 6, y: c.y + n.y * 6))], text: nil, size: .small))
                }
            }
        }
        if !marks.isEmpty {
            out.actions.append(.draw(DrawAction(ink: .pen, color: action.color, shapes: marks, caption: "marks on \(shape.id)")))
        }
        return out
    }
}
