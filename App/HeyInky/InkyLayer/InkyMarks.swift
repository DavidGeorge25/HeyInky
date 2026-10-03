import SwiftUI

// Renderers for page annotations. Each mark draws inside its own frame (the annotation's
// bounds converted to view points); `scale` is view points per page point.

struct HighlightMark: View {
    let action: HighlightAction
    let scale: CGFloat

    var body: some View {
        let color = Theme.highlightColor(action.color)
        RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
            .fill(color.opacity(0.38))
            .overlay(alignment: .topTrailing) {
                if let note = action.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.75))
                        .padding(.horizontal, 6 * scale)
                        .padding(.vertical, 2 * scale)
                        .background(Capsule().fill(color))
                        .fixedSize()
                        .offset(y: -16 * scale)
                }
            }
    }
}

struct CircleMark: View {
    let action: CircleAction
    let scale: CGFloat
    let seed: Int

    var body: some View {
        HandDrawnLoop(seed: seed)
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

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let phase = Double(abs(seed % 628)) / 100
        let steps = 90
        let sweep = 2 * Double.pi * 1.08
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let theta = -Double.pi / 2 + phase * 0.1 + t * sweep
            let wobble = 1 + 0.035 * sin(3 * theta + phase) + 0.02 * t
            let x = rect.midX + rect.width / 2 * wobble * cos(theta)
            let y = rect.midY + rect.height / 2 * wobble * sin(theta)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

struct StarMark: View {
    var body: some View {
        StarShape()
            .fill(Theme.accent)
            .overlay(StarShape().stroke(.white.opacity(0.9), lineWidth: 1))
    }
}

struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.45
        for i in 0..<10 {
            let r = i.isMultiple(of: 2) ? outer : inner
            let angle = -Double.pi / 2 + Double(i) * Double.pi / 5
            let p = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

/// Label text plus optional arrow to its anchor. Drawn within the label's bounds.
struct LabelMark: View {
    let action: LabelAction
    let pageSize: CGSize
    /// Bounds of the whole annotation (text + anchor), normalized, before user offset.
    let bounds: NormRect
    let scale: CGFloat

    var body: some View {
        let textRect = InkyAnnotationGeometry.labelTextRect(action, pageSize: pageSize)
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
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round, lineJoin: .round))
            }
            Text(action.text)
                .font(Font(InkyAnnotationGeometry.labelFont(scale: scale)))
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, InkyAnnotationGeometry.labelPadding.width * scale)
                .padding(.vertical, InkyAnnotationGeometry.labelPadding.height * scale)
                .frame(width: textSize.width, height: textSize.height, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                        .fill(Color.white.opacity(0.92))
                        .overlay(RoundedRectangle(cornerRadius: 6 * scale, style: .continuous).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
                )
                .offset(x: textOrigin.x, y: textOrigin.y)
        }
    }

    /// Point on `rect`'s border along the segment from its center to `target`.
    static func edgePoint(of rect: CGRect, toward target: CGPoint) -> CGPoint {
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

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Gentle curve, like a hand-drawn arrow.
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let normal = CGPoint(x: -(to.y - from.y) * 0.15, y: (to.x - from.x) * 0.15)
        let control = CGPoint(x: mid.x + normal.x, y: mid.y + normal.y)
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

    var body: some View {
        GeometryReader { geo in
            let fontSize = min(22 * scale, max(10 * scale, geo.size.height * 0.75))
            Text(action.text)
                .font(action.handwritingStyle ? Theme.handwriting(size: fontSize) : .system(size: fontSize * 0.85, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.accent)
                .minimumScaleFactor(0.25)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
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
