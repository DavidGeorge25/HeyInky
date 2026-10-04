import SwiftUI
import UIKit

// Renderers for page annotations. Each mark draws inside its own frame (the annotation's
// bounds converted to view points); `scale` is view points per page point.

// Every mark takes a `progress` (0…1) for the stroke-reveal while Inky draws it; 1 = done.

struct HighlightMark: View {
    let action: HighlightAction
    let scale: CGFloat
    var progress: CGFloat = 1
    /// Where the note tag goes, relative to the highlight's top-left, in view points
    /// (from `InkyLayout.noteCandidates`). nil = above the right end.
    var noteOffset: CGPoint?

    var body: some View {
        let color = Theme.highlightColor(action.color)
        MarkerSwipe(scale: scale)
            .fill(color.opacity(0.38))
            .overlay(alignment: .topLeading) {
                if let note = action.note, !note.isEmpty {
                    Text(note)
                        .font(Font(InkyLayout.noteFont(scale: scale)))
                        .foregroundStyle(.black.opacity(0.75))
                        .padding(.horizontal, InkyLayout.notePadding.width * scale)
                        .padding(.vertical, InkyLayout.notePadding.height * scale)
                        .background(Capsule().fill(color))
                        .fixedSize()
                        .offset(x: noteOffset?.x ?? 0, y: noteOffset?.y ?? -16 * scale)
                        .opacity(progress >= 1 ? 1 : 0)
                }
            }
            .revealed(progress)
    }
}

/// A chisel-marker swipe: straight body, faintly uneven edges, slightly slanted ends.
struct MarkerSwipe: Shape {
    var scale: CGFloat

    func path(in rect: CGRect) -> Path {
        let slant = min(3 * scale, rect.width * 0.05, rect.height * 0.2)
        let wave = min(0.8 * scale, rect.height * 0.04)
        let steps = max(2, Int(rect.width / max(6 * scale, 1)))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + slant, y: rect.minY))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = rect.minX + slant + (rect.width - 2 * slant) * t
            path.addLine(to: CGPoint(x: x, y: rect.minY + wave * sin(t * 13 + 1)))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        for i in stride(from: steps, through: 0, by: -1) {
            let t = CGFloat(i) / CGFloat(steps)
            let x = rect.minX + (rect.width - 2 * slant) * t
            path.addLine(to: CGPoint(x: x, y: rect.maxY - wave * sin(t * 11 + 2)))
        }
        path.closeSubpath()
        return path
    }
}

/// Reveals content left to right; keeps overflow (notes, flourishes) above and below.
struct LeadingReveal: Shape {
    var progress: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 2000, y: rect.minY - 2000, width: 2000 + rect.width * progress, height: rect.height + 4000))
    }
}

extension View {
    /// Masks the view to its first `progress` of width while it's being drawn.
    @ViewBuilder func revealed(_ progress: CGFloat, widthFraction: CGFloat = 1) -> some View {
        if progress >= 1 {
            self
        } else {
            mask(LeadingReveal(progress: max(0, progress) * widthFraction))
        }
    }
}

struct CircleMark: View {
    let action: CircleAction
    let scale: CGFloat
    let seed: Int
    var progress: CGFloat = 1

    /// Stable per-annotation variation of the loop.
    nonisolated static func seed(for id: UUID) -> Int {
        Int(id.uuid.0) * 31 + Int(id.uuid.1)
    }

    var body: some View {
        HandDrawnLoop(seed: seed)
            .trim(from: 0, to: min(max(progress, 0), 1))
            .stroke(
                Theme.accent,
                style: StrokeStyle(
                    lineWidth: 2.5 * scale, lineCap: .round, lineJoin: .round,
                    dash: action.style == .dashed ? [7 * scale, 6 * scale] : []
                )
            )
    }
}

/// An ellipse drawn like a quick pen loop: slightly uneven radius, ends overlapping.
struct HandDrawnLoop: Shape {
    var seed: Int

    static let steps = 90

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0...Self.steps {
            let p = Self.point(at: CGFloat(i) / CGFloat(Self.steps), in: rect, seed: seed)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    /// Point on the loop at `t` (0…1) of the way along it.
    static func point(at t: CGFloat, in rect: CGRect, seed: Int) -> CGPoint {
        let phase = Double(abs(seed % 628)) / 100
        let sweep = 2 * Double.pi * 1.08
        let theta = -Double.pi / 2 + phase * 0.1 + Double(t) * sweep
        let wobble: Double = 1 + 0.035 * sin(3 * theta + phase) + 0.02 * Double(t)
        let rx = Double(rect.width) / 2 * wobble, ry = Double(rect.height) / 2 * wobble
        return CGPoint(x: Double(rect.midX) + rx * cos(theta), y: Double(rect.midY) + ry * sin(theta))
    }
}

struct StarMark: View {
    var progress: CGFloat = 1

    /// Outline first, then the fill flows in and the star pops.
    static let outlineShare: CGFloat = 0.7

    var body: some View {
        let outline = min(1, progress / Self.outlineShare)
        let fill = max(0, (progress - Self.outlineShare) / (1 - Self.outlineShare))
        ZStack {
            StarShape()
                .fill(Theme.accent)
                .opacity(fill)
            StarShape()
                .trim(from: 0, to: outline)
                .stroke(progress >= 1 ? Color.white.opacity(0.9) : Theme.accent,
                        style: StrokeStyle(lineWidth: progress >= 1 ? 1 : 1.6, lineCap: .round, lineJoin: .round))
        }
        .scaleEffect(progress >= 1 ? 1 : 1 + 0.18 * sin(fill * .pi))
    }
}

struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (i, p) in Self.vertices(in: rect).enumerated() {
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    static func vertices(in rect: CGRect) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.45
        return (0..<10).map { i in
            let r = i.isMultiple(of: 2) ? outer : inner
            let angle = -Double.pi / 2 + Double(i) * Double.pi / 5
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
    }

    /// Point `t` (0…1) of the way around the outline, starting at the top point.
    static func outlinePoint(at t: CGFloat, in rect: CGRect) -> CGPoint {
        let v = vertices(in: rect)
        let position = min(max(t, 0), 1) * 10
        let i = min(Int(position), 9)
        let u = position - CGFloat(i)
        let a = v[i], b = v[(i + 1) % 10]
        return CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
    }
}

/// Label text plus optional arrow to its anchor. Drawn within the label's bounds.
struct LabelMark: View {
    let action: LabelAction
    let pageSize: CGSize
    var placement: Int = 0
    /// Bounds of the whole annotation (text + anchor), normalized, before user offset.
    let bounds: NormRect
    let scale: CGFloat
    var progress: CGFloat = 1

    var body: some View {
        let textShare = action.arrow ? InkyStroke.labelTextShare : 1
        let textProgress = min(1, progress / textShare)
        let arrowProgress = action.arrow ? max(0, (progress - textShare) / (1 - textShare)) : 0
        let textRect = InkyAnnotationGeometry.labelTextRect(action, pageSize: pageSize, placement: placement)
        let local = { (p: NormPoint) -> CGPoint in
            CGPoint(x: (p.x - bounds.x) * pageSize.width * scale, y: (p.y - bounds.y) * pageSize.height * scale)
        }
        let textOrigin = local(NormPoint(x: textRect.x, y: textRect.y))
        let textSize = CGSize(width: textRect.width * pageSize.width * scale, height: textRect.height * pageSize.height * scale)
        let anchor = local(action.anchor)

        ZStack(alignment: .topLeading) {
            if action.arrow {
                let start = Self.edgePoint(of: CGRect(origin: textOrigin, size: textSize), toward: anchor)
                ArrowShape(from: start, to: anchor, headLength: 8 * scale)
                    .trim(from: 0, to: progress >= 1 ? 1 : arrowProgress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round, lineJoin: .round))
            }
            Text(action.text)
                .font(Font(InkyAnnotationGeometry.labelFont(scale: scale)))
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, InkyAnnotationGeometry.labelPadding.width * scale)
                .padding(.vertical, InkyAnnotationGeometry.labelPadding.height * scale)
                .frame(width: textSize.width, height: textSize.height, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                        .fill(Color.white.opacity(0.92))
                        .overlay(RoundedRectangle(cornerRadius: 6 * scale, style: .continuous).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                )
                .revealed(textProgress)
                .offset(x: textOrigin.x, y: textOrigin.y)
        }
    }

    /// Point on `rect`'s border along the segment from its center to `target`.
    nonisolated static func edgePoint(of rect: CGRect, toward target: CGPoint) -> CGPoint {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - c.x, dy = target.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let tx = dx == 0 ? CGFloat.infinity : (rect.width / 2) / abs(dx)
        let ty = dy == 0 ? CGFloat.infinity : (rect.height / 2) / abs(dy)
        let t = min(tx, ty, 1)
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }
}

struct ArrowShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var headLength: CGFloat

    /// Gentle curve, like a hand-drawn arrow.
    static func control(from: CGPoint, to: CGPoint) -> CGPoint {
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        return CGPoint(x: mid.x - (to.y - from.y) * 0.15, y: mid.y + (to.x - from.x) * 0.15)
    }

    /// Point `t` (0…1) along the arrow's shaft.
    static func point(at t: CGFloat, from: CGPoint, to: CGPoint) -> CGPoint {
        let c = control(from: from, to: to)
        let u = 1 - t
        return CGPoint(x: u * u * from.x + 2 * u * t * c.x + t * t * to.x,
                       y: u * u * from.y + 2 * u * t * c.y + t * t * to.y)
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let control = Self.control(from: from, to: to)
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)
        let angle = atan2(to.y - control.y, to.x - control.x)
        for side in [-1.0, 1.0] {
            let a = angle + .pi - side * .pi / 7
            path.move(to: to)
            path.addLine(to: CGPoint(x: to.x + headLength * cos(a), y: to.y + headLength * sin(a)))
        }
        return path
    }
}

struct FillTextMark: View {
    let action: FillTextAction
    let scale: CGFloat
    var progress: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Text(action.text)
                .font(action.handwritingStyle ? Theme.handwriting(size: Self.fontSize(for: geo.size.height, scale: scale)) : .system(size: Self.fontSize(for: geo.size.height, scale: scale) * 0.85, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.accent)
                .minimumScaleFactor(0.25)
                // Off the box's left border, like a person writing inside it.
                .padding(.leading, Self.leadingInset(width: geo.size.width, scale: scale))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .revealed(progress, widthFraction: Self.textWidthFraction(action, size: geo.size, scale: scale))
        }
    }

    nonisolated static func leadingInset(width: CGFloat, scale: CGFloat) -> CGFloat {
        min(8 * scale, width * 0.08)
    }

    nonisolated static func fontSize(for height: CGFloat, scale: CGFloat) -> CGFloat {
        min(22 * scale, max(10 * scale, height * 0.75))
    }

    /// Roughly how much of the region's width the text covers, so the reveal (and Inky's nib)
    /// stop where the writing ends.
    nonisolated static func textWidthFraction(_ action: FillTextAction, size: CGSize, scale: CGFloat) -> CGFloat {
        guard size.width > 0 else { return 1 }
        let fontSize = fontSize(for: size.height, scale: scale)
        let font = action.handwritingStyle
            ? (UIFont(name: "Noteworthy-Bold", size: fontSize) ?? .systemFont(ofSize: fontSize))
            : .systemFont(ofSize: fontSize * 0.85)
        let width = (action.text as NSString).size(withAttributes: [.font: font]).width
        return min(1, max(0.15, (width + leadingInset(width: size.width, scale: scale) + 4 * scale) / size.width))
    }
}

/// Shared chrome for interactive cards (molecule, graph) so modules only draw content.
struct InkyCardContainer<Content: View>: View {
    let title: String
    let systemImage: String
    let scale: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12 * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 8 * scale)
            Divider().opacity(0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .inkySurface(cornerRadius: 12 * scale)
    }
}

extension View {
    /// Cards pop in under Inky's nib.
    @ViewBuilder func cardReveal(_ progress: CGFloat) -> some View {
        if progress >= 1 {
            self
        } else {
            let p = max(0, progress)
            scaleEffect(0.86 + 0.14 * (1 - (1 - p) * (1 - p)), anchor: .bottom)
                .opacity(Double(min(1, p * 2)))
        }
    }
}

/// Inky's own drawing: real PencilKit ink (rendered from `DrawInk` strokes) plus handwriting.
/// While Inky draws it, ink appears up to the nib (`progress`).
struct DrawMark: View {
    let action: DrawAction
    let seed: Int
    let pageSize: CGSize
    let scale: CGFloat
    var progress: CGFloat = 1
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let layout = DrawInk.layout(action, pageSize: pageSize, seed: seed)
        let textProgress = DrawInk.textProgress(layout, progress: progress)
        let color = Color(DrawInk.uiColor(action.color))
        ZStack(alignment: .topLeading) {
            if let image = Self.image(layout, action: action, progress: progress, scale: scale * displayScale, seed: seed) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: layout.bounds.width * scale, height: layout.bounds.height * scale)
            }
            ForEach(Array(layout.segments.enumerated()), id: \.offset) { index, segment in
                if let text = segment.text, let shown = textProgress[index], shown > 0 {
                    Text(text.string)
                        .font(Font(DrawInk.handwritingFont(size: text.fontSize * scale)))
                        .foregroundStyle(color)
                        .fixedSize()
                        .revealed(shown)
                        .offset(x: (text.origin.x - layout.bounds.minX) * scale, y: (text.origin.y - layout.bounds.minY) * scale)
                }
            }
        }
        .frame(width: layout.bounds.width * scale, height: layout.bounds.height * scale, alignment: .topLeading)
    }

    private static let cache = NSCache<NSString, UIImage>()

    /// The ink as an image of the layout's bounds. Finished drawings are cached per zoom step.
    static func image(_ layout: DrawInk.Layout, action: DrawAction, progress: CGFloat, scale: CGFloat, seed: Int) -> UIImage? {
        // Bitmaps stay bounded when zoomed far in; quantized so zooming doesn't thrash the cache.
        let maxSide = max(layout.bounds.width, layout.bounds.height, 1)
        let renderScale = min((scale * 4).rounded(.up) / 4, 4096 / maxSide)
        let key = "\(action.hashValue)-\(seed)-\(renderScale)" as NSString
        if progress >= 1, let cached = cache.object(forKey: key) { return cached }
        let drawing = DrawInk.drawing(layout, action: action, progress: progress)
        guard !drawing.strokes.isEmpty else { return nil }
        var image: UIImage?
        // Paper is white: always render light ink (PencilKit inverts colors in dark mode).
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: layout.bounds, scale: renderScale)
        }
        if progress >= 1, let image { cache.setObject(image, forKey: key) }
        return image
    }
}
