import PencilKit
import UIKit

/// Turns a `draw` action into what a hand would do: an ordered list of pen strokes (page points)
/// and handwritten text. Shared by the renderer (`DrawMark`, real PencilKit ink) and Inky's nib
/// (`InkyStroke`), so ink appears exactly under the nib while Inky draws.
enum DrawInk {
    /// One pen-down movement, or one piece of handwriting.
    struct Segment: Equatable, Sendable {
        var points: [CGPoint]
        var text: TextItem?
        /// Ink length in page points (text: how long writing it takes, in the same units).
        var length: CGFloat
        /// Pen width, page points.
        var width: CGFloat = 0
    }

    struct TextItem: Equatable, Sendable {
        var string: String
        /// Top-left, page points.
        var origin: CGPoint
        var fontSize: CGFloat
        var size: CGSize
        var rect: CGRect { CGRect(origin: origin, size: size) }
    }

    struct Layout: Equatable, Sendable {
        var segments: [Segment]
        /// Everything drawn, padded for the stroke width, page points.
        var bounds: CGRect
        var totalLength: CGFloat
        var lineWidth: CGFloat
    }

    // MARK: Style

    static func uiColor(_ color: DrawAction.Color) -> UIColor {
        switch color {
        case .indigo: Theme.accentUI
        case .black: UIColor(white: 0.12, alpha: 1)
        case .blue: UIColor(red: 0.18, green: 0.43, blue: 0.87, alpha: 1)
        case .red: UIColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1)
        case .green: UIColor(red: 0.19, green: 0.62, blue: 0.40, alpha: 1)
        case .orange: UIColor(red: 0.95, green: 0.45, blue: 0.10, alpha: 1)
        }
    }

    static func lineWidth(_ ink: DrawAction.Ink, size: DrawAction.Shape.Size) -> CGFloat {
        let base: CGFloat = switch ink {
        case .pen: 3.3
        case .pencil: 2.8
        case .marker: 9
        }
        return base * (size == .small ? 0.9 : size == .large ? 1.5 : 1)
    }

    static func fontSize(_ size: DrawAction.Shape.Size) -> CGFloat {
        switch size {
        case .small: 15
        case .medium: 20
        case .large: 28
        }
    }

    static func handwritingFont(size: CGFloat) -> UIFont {
        UIFont(name: "Noteworthy-Bold", size: size) ?? .systemFont(ofSize: size, weight: .medium)
    }

    // MARK: Layout

    /// NSCache is thread-safe.
    nonisolated(unsafe) private static let cache = NSCache<NSString, LayoutBox>()
    private final class LayoutBox { let layout: Layout; init(_ l: Layout) { layout = l } }

    /// The strokes for `action` on a page of `pageSize`. `seed` varies the hand wobble per annotation.
    static func layout(_ action: DrawAction, pageSize: CGSize, seed: Int = 0) -> Layout {
        let key = "\(action.hashValue)-\(seed)-\(pageSize.width)x\(pageSize.height)" as NSString
        if let cached = cache.object(forKey: key) { return cached.layout }

        // 1. Text first: where it goes decides how circles/boxes around it are drawn.
        let placement = placeTexts(action, pageSize: pageSize)
        let texts = placement.texts
        let textRects = texts.values.map(\.rect)

        // 2. Strokes and writing in the order the model gave them.
        var segments: [Segment] = []
        var maxWidth: CGFloat = 0
        for (index, shape) in action.shapes.enumerated() {
            if let item = texts[index] {
                // The nib writes along each line of text.
                let lines = CGFloat(max(1, item.string.components(separatedBy: "\n").count))
                let lineHeight = item.size.height / lines
                let nib = [CGPoint(x: item.origin.x, y: item.origin.y + lineHeight * 0.7),
                           CGPoint(x: item.origin.x + item.size.width, y: item.origin.y + item.size.height - lineHeight * 0.3)]
                segments.append(Segment(points: nib, text: item, length: max(20, item.size.width * 0.6 + item.size.height * 0.4)))
                continue
            }
            let width = lineWidth(action.ink, size: shape.size)
            maxWidth = max(maxWidth, width)
            var pts = shape.points.map { $0.cgPoint(in: pageSize) }
            for (pointIndex, moved) in placement.bondEnds[index] ?? [:] { pts[pointIndex] = moved }
            if let snapped = snapEnclosure(shape.kind, pts, to: textRects) { pts = snapped }
            var noise = Wobble(seed: seed &* 31 &+ index, amplitude: action.ink == .marker ? 0.9 : 0.55)
            for path in paths(for: shape, points: pts, lineWidth: width, pageSize: pageSize) {
                let wobbly = path.count > 1 ? noise.apply(to: densify(path, spacing: 3)) : path
                segments.append(Segment(points: wobbly, text: nil, length: polylineLength(wobbly), width: width))
            }
        }
        var bounds = CGRect.null
        for s in segments {
            if let t = s.text { bounds = bounds.union(t.rect) }
            for p in s.points where s.text == nil { bounds = bounds.union(CGRect(origin: p, size: .zero)) }
        }
        if bounds.isNull { bounds = CGRect(x: pageSize.width / 2, y: pageSize.height / 2, width: 1, height: 1) }
        bounds = bounds.insetBy(dx: -(maxWidth + 4), dy: -(maxWidth + 4))
        let layout = Layout(segments: segments, bounds: bounds, totalLength: segments.reduce(0) { $0 + $1.length }, lineWidth: maxWidth)
        cache.setObject(LayoutBox(layout), forKey: key)
        return layout
    }

    // MARK: Text placement

    /// Short labels ("H", "δ+", "OH") are atom/charge symbols: centered on their point.
    static let shortLabelLength = 4

    static func isShortLabel(_ text: String) -> Bool {
        text.count <= shortLabelLength && !text.contains("\n")
    }

    static func measure(_ string: String, size: DrawAction.Shape.Size, pageSize: CGSize) -> (CGSize, CGFloat) {
        let fontSize = fontSize(size)
        let measured = (string as NSString).boundingRect(
            with: CGSize(width: pageSize.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: handwritingFont(size: fontSize)], context: nil
        ).size
        return (CGSize(width: ceil(measured.width) + 4, height: ceil(measured.height) + 2), fontSize)
    }

    /// Text items by shape index. A short label sitting at the end of one of this drawing's lines
    /// is written just past that end (like "H" at the end of a C–H bond); labels that would
    /// collide slide apart (outward along their bond, or down for lines of working).
    struct TextPlacement {
        var texts: [Int: TextItem] = [:]
        /// Bonds lengthened to reach a label that had to move out: shape index → point index → new point.
        var bondEnds: [Int: [Int: CGPoint]] = [:]
    }

    static func placeTexts(_ action: DrawAction, pageSize: CGSize) -> TextPlacement {
        struct LineEnd { var end: CGPoint; var from: CGPoint; var shape: Int; var point: Int }
        let lineEnds: [LineEnd] = action.shapes.enumerated().flatMap { index, shape -> [LineEnd] in
            guard [.line, .dashedLine, .polyline].contains(shape.kind), shape.points.count >= 2 else { return [] }
            let p = shape.points.map { $0.cgPoint(in: pageSize) }
            return [LineEnd(end: p[p.count - 1], from: p[p.count - 2], shape: index, point: p.count - 1),
                    LineEnd(end: p[0], from: p[1], shape: index, point: 0)]
        }
        var result = TextPlacement()
        var placed: [CGRect] = []
        for (index, shape) in action.shapes.enumerated() where shape.kind == .text {
            guard let string = shape.text?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty,
                  let point = shape.points.first?.cgPoint(in: pageSize) else { continue }
            let (size, fontSize) = measure(string, size: shape.size, pageSize: pageSize)
            var rect: CGRect
            var direction: CGPoint?
            var bond: LineEnd?
            if isShortLabel(string) {
                // Anchored to a bond end nearby? Write it just past the end, along the bond.
                let near = lineEnds.min { hypot($0.end.x - point.x, $0.end.y - point.y) < hypot($1.end.x - point.x, $1.end.y - point.y) }
                if let near, hypot(near.end.x - point.x, near.end.y - point.y) < 18 {
                    bond = near
                    let d = CGPoint(x: near.end.x - near.from.x, y: near.end.y - near.from.y)
                    let len = max(hypot(d.x, d.y), 0.001)
                    let dir = CGPoint(x: d.x / len, y: d.y / len)
                    direction = dir
                    let reach = abs(dir.x) * size.width / 2 + abs(dir.y) * size.height / 2 + 1.5
                    let center = CGPoint(x: near.end.x + dir.x * reach, y: near.end.y + dir.y * reach)
                    rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
                } else {
                    rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                }
            } else {
                rect = CGRect(origin: point, size: size)
            }
            let before = rect
            rect = resolve(rect, against: placed, direction: direction, isShort: isShortLabel(string), pageSize: pageSize)
            placed.append(rect)
            result.texts[index] = TextItem(string: string, origin: rect.origin, fontSize: fontSize, size: size)
            // Moved out along its bond: lengthen the bond so the atom stays attached.
            if let bond, let d = direction, rect != before {
                let along = (rect.midX - before.midX) * d.x + (rect.midY - before.midY) * d.y
                if along > 0 {
                    let end = CGPoint(x: bond.end.x + d.x * along, y: bond.end.y + d.y * along)
                    result.bondEnds[bond.shape, default: [:]][bond.point] = end
                }
            }
        }
        return result
    }

    /// Moves `rect` off the others: along `direction` (a bond) for labels, down/up for lines of
    /// text, small sideways steps otherwise. Keeps the original spot if nothing is free.
    static func resolve(_ rect: CGRect, against others: [CGRect], direction: CGPoint?, isShort: Bool, pageSize: CGSize) -> CGRect {
        func collides(_ r: CGRect) -> Bool {
            others.contains { o in
                let i = r.intersection(o)
                return !i.isNull && i.width * i.height > 0.08 * min(r.width * r.height, o.width * o.height)
            }
        }
        guard collides(rect) else { return rect }
        let h = rect.height, w = rect.width
        var offsets: [CGPoint] = []
        if let d = direction {
            offsets += (1...4).map { k in CGPoint(x: d.x * h * 0.45 * CGFloat(k), y: d.y * h * 0.45 * CGFloat(k)) }
            // Or fan out sideways from the bond.
            offsets += [0.6, -0.6, 1.1, -1.1].map { k in CGPoint(x: -d.y * h * k, y: d.x * h * k) }
        } else if isShort {
            offsets += [CGPoint(x: 0, y: -0.7 * h), CGPoint(x: 0, y: 0.7 * h), CGPoint(x: 0.7 * w, y: 0), CGPoint(x: -0.7 * w, y: 0),
                        CGPoint(x: 0, y: -1.3 * h), CGPoint(x: 0, y: 1.3 * h)]
        } else {
            offsets += (1...5).flatMap { k in [CGPoint(x: 0, y: h * 1.05 * CGFloat(k)), CGPoint(x: 0, y: -h * 1.05 * CGFloat(k))] }
        }
        let page = CGRect(origin: .zero, size: pageSize).insetBy(dx: 4, dy: 4)
        for o in offsets {
            let candidate = rect.offsetBy(dx: o.x, dy: o.y)
            if page.contains(candidate), !collides(candidate) { return candidate }
        }
        return rect
    }

    /// An ellipse or box drawn around one of the drawing's texts is fitted to that text, so the
    /// circle around "x = −1/2" encloses it instead of cutting through it.
    static func snapEnclosure(_ kind: DrawAction.Shape.Kind, _ p: [CGPoint], to texts: [CGRect]) -> [CGPoint]? {
        let box: CGRect
        switch kind {
        case .ellipse where p.count == 2:
            box = CGRect(x: min(p[0].x, p[1].x), y: min(p[0].y, p[1].y), width: abs(p[1].x - p[0].x), height: abs(p[1].y - p[0].y))
        case .polygon where p.count == 4:
            let xs = p.map(\.x), ys = p.map(\.y)
            box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        default:
            return nil
        }
        // The text it was meant to enclose: mostly inside the box, and the box not much bigger.
        let target = texts.max { a, b in coverage(a, by: box) < coverage(b, by: box) }
        guard let t = target, coverage(t, by: box) >= 0.4, box.width * box.height <= 8 * t.width * t.height else { return nil }
        if kind == .ellipse {
            // An ellipse through the text box's corners, plus a little air.
            let fit = t.insetBy(dx: -(t.width * 0.2 + 6), dy: -(t.height * 0.32 + 5))
            return [CGPoint(x: fit.minX, y: fit.minY), CGPoint(x: fit.maxX, y: fit.maxY)]
        }
        let fit = t.insetBy(dx: -8, dy: -6)
        return [CGPoint(x: fit.minX, y: fit.minY), CGPoint(x: fit.maxX, y: fit.minY), CGPoint(x: fit.maxX, y: fit.maxY), CGPoint(x: fit.minX, y: fit.maxY)]
    }

    private static func coverage(_ text: CGRect, by box: CGRect) -> CGFloat {
        let i = text.intersection(box)
        guard !i.isNull, text.width * text.height > 0 else { return 0 }
        return i.width * i.height / (text.width * text.height)
    }

    /// Pen-down paths for one shape.
    private static func paths(for shape: DrawAction.Shape, points p: [CGPoint], lineWidth: CGFloat, pageSize: CGSize) -> [[CGPoint]] {
        let head = max(9, lineWidth * 3.6)
        switch shape.kind {
        case .text:
            return []
        case .line, .polyline:
            return p.count >= 2 ? [p] : []
        case .polygon:
            return p.count >= 3 ? [p + [p[0]]] : []
        case .dashedLine:
            guard p.count >= 2 else { return [] }
            return dashes(densify(p, spacing: 1), dash: 7, gap: 5)
        case .arrow:
            guard p.count >= 2 else { return [] }
            return [p, arrowHead(tip: p[p.count - 1], from: p[p.count - 2], length: head)]
        case .doubleArrow:
            guard p.count >= 2 else { return [] }
            return [p, arrowHead(tip: p[p.count - 1], from: p[p.count - 2], length: head), arrowHead(tip: p[0], from: p[1], length: head)]
        case .curvedArrow:
            guard p.count >= 2, let start = p.first, let end = p.last else { return [] }
            let control: CGPoint
            if p.count >= 3 {
                // Quadratic through the middle point.
                let m = p[p.count / 2]
                control = CGPoint(x: 2 * m.x - (start.x + end.x) / 2, y: 2 * m.y - (start.y + end.y) / 2)
            } else {
                // Bow to the left of travel, a third of the length.
                let d = CGPoint(x: end.x - start.x, y: end.y - start.y)
                let len = max(hypot(d.x, d.y), 1)
                control = CGPoint(x: (start.x + end.x) / 2 + d.y / len * len * 0.35, y: (start.y + end.y) / 2 - d.x / len * len * 0.35)
            }
            let curve = (0...28).map { i -> CGPoint in
                let t = CGFloat(i) / 28
                let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
                return CGPoint(x: a * start.x + b * control.x + c * end.x, y: a * start.y + b * control.y + c * end.y)
            }
            return [curve, arrowHead(tip: end, from: curve[curve.count - 3], length: head)]
        case .ellipse:
            guard p.count >= 2 else { return [] }
            let box = CGRect(x: min(p[0].x, p[1].x), y: min(p[0].y, p[1].y), width: abs(p[1].x - p[0].x), height: abs(p[1].y - p[0].y))
            guard box.width > 1 || box.height > 1 else { return [] }
            // A hand-drawn loop starts near the top and overshoots a little.
            return [(0...48).map { i -> CGPoint in
                let angle = -CGFloat.pi * 0.6 + CGFloat(i) / 48 * 2.08 * .pi
                return CGPoint(x: box.midX + box.width / 2 * cos(angle), y: box.midY + box.height / 2 * sin(angle))
            }]
        }
    }

    /// A "V" stroke: one wing, the tip, the other wing.
    private static func arrowHead(tip: CGPoint, from: CGPoint, length: CGFloat) -> [CGPoint] {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let spread: CGFloat = 0.5
        let left = CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread))
        let right = CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread))
        return [left, tip, right]
    }

    private static func dashes(_ points: [CGPoint], dash: CGFloat, gap: CGFloat) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var travelled: CGFloat = 0
        for (i, p) in points.enumerated() {
            if i > 0 { travelled += hypot(p.x - points[i - 1].x, p.y - points[i - 1].y) }
            let phase = travelled.truncatingRemainder(dividingBy: dash + gap)
            if phase < dash {
                current.append(p)
            } else if !current.isEmpty {
                if current.count > 1 { result.append(current) }
                current = []
            }
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    static func densify(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var result = [last]
        for p in points.dropFirst() {
            let d = hypot(p.x - last.x, p.y - last.y)
            let steps = max(1, Int(d / spacing))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                result.append(CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t))
            }
            last = p
        }
        return result
    }

    static func polylineLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Smooth, low-frequency sideways drift: steady like a confident hand, not jittery.
    private struct Wobble {
        var seed: Int
        var amplitude: CGFloat

        mutating func apply(to points: [CGPoint]) -> [CGPoint] {
            guard points.count > 2 else { return points }
            let phase = CGFloat(abs(seed) % 628) / 100
            let frequency = 0.035 + CGFloat(abs(seed / 7) % 20) / 1000
            var travelled: CGFloat = 0
            return points.enumerated().map { i, p in
                if i > 0 { travelled += hypot(p.x - points[i - 1].x, p.y - points[i - 1].y) }
                let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
                let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
                let len = max(hypot(d.x, d.y), 0.0001)
                let n = CGPoint(x: -d.y / len, y: d.x / len)
                // Ends stay put so strokes meet where they should (bonds at atoms, arrow tips).
                let fade = min(1, CGFloat(min(i, points.count - 1 - i)) / 4)
                let offset = amplitude * fade * sin(travelled * frequency + phase)
                return CGPoint(x: p.x + n.x * offset, y: p.y + n.y * offset)
            }
        }
    }

    // MARK: Ink

    /// Real PencilKit strokes for the first `progress` (0…1) of the drawing's ink.
    static func drawing(_ layout: Layout, action: DrawAction, progress: CGFloat = 1) -> PKDrawing {
        let inkType: PKInk.InkType = switch action.ink {
        case .pen: .pen
        case .pencil: .pencil
        case .marker: .marker
        }
        let color = uiColor(action.color)
        let ink = PKInk(inkType, color: action.ink == .marker ? color.withAlphaComponent(0.55) : color)
        var remaining = layout.totalLength * min(max(progress, 0), 1)
        var strokes: [PKStroke] = []
        for segment in layout.segments {
            guard remaining > 0 else { break }
            defer { remaining -= segment.length }
            guard segment.text == nil, segment.points.count > 1 else { continue }
            let width = segment.width
            var points = segment.points
            if remaining < segment.length {
                points = Array(points.prefix(max(2, Int(CGFloat(points.count) * remaining / segment.length))))
            }
            let n = points.count
            let strokePoints = points.enumerated().map { i, p -> PKStrokePoint in
                // A slight taper at both ends; full force (PencilKit's pen thins and pales with low force).
                let ends = min(CGFloat(min(i, n - 1 - i)) / 3, 1)
                let w = width * (0.8 + 0.2 * ends)
                // An unhurried hand (~150 pt/s): PencilKit thins fast strokes.
                return PKStrokePoint(location: p, timeOffset: Double(i) * 0.02, size: CGSize(width: w, height: w),
                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: strokePoints, creationDate: Date(timeIntervalSince1970: 0))))
        }
        return PKDrawing(strokes: strokes)
    }

    /// How much of each text item is written at `progress` (0 = not yet, 1 = done), by segment index.
    static func textProgress(_ layout: Layout, progress: CGFloat) -> [Int: CGFloat] {
        var result: [Int: CGFloat] = [:]
        var start: CGFloat = 0
        let total = max(layout.totalLength, 0.0001)
        let at = min(max(progress, 0), 1) * total
        for (i, s) in layout.segments.enumerated() {
            if s.text != nil { result[i] = min(max((at - start) / max(s.length, 0.0001), 0), 1) }
            start += s.length
        }
        return result
    }

    /// Where the nib is at `progress`, page points (jumps between strokes like a lifted pen).
    static func nib(_ layout: Layout, at progress: CGFloat) -> CGPoint {
        var remaining = layout.totalLength * min(max(progress, 0), 1)
        for s in layout.segments {
            if remaining <= s.length || s == layout.segments.last {
                return point(along: s.points, distance: min(remaining, s.length), total: s.length)
            }
            remaining -= s.length
        }
        return CGPoint(x: layout.bounds.midX, y: layout.bounds.midY)
    }

    private static func point(along points: [CGPoint], distance: CGFloat, total: CGFloat) -> CGPoint {
        guard let first = points.first else { return .zero }
        // Text segments: distance is a fraction of the writing, not of the 2-point nib line.
        let real = polylineLength(points)
        var remaining = total > 0 ? distance / total * real : 0
        var last = first
        for p in points.dropFirst() {
            let d = hypot(p.x - last.x, p.y - last.y)
            if remaining <= d, d > 0 {
                let t = remaining / d
                return CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t)
            }
            remaining -= d
            last = p
        }
        return last
    }
}
