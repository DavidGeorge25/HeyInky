import SwiftUI

/// Inky's colors: the app accent for the body, a deep ink for the nib and features, white.
enum InkyPalette {
    static let body = Theme.accent
    static let ink = Color(red: 0.16, green: 0.15, blue: 0.42)
    static let blush = Color(red: 1.0, green: 0.56, blue: 0.7)
}

/// Draws one pose of Inky: a chubby fountain pen standing on its nib, with a big-eyed face
/// on the barrel and an ink drop on its head. Pure vector, drawn into a `size × size` frame.
struct InkyFigure: View {
    var pose: InkyPose
    var size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            InkyDrawing.draw(pose, in: context, side: min(canvasSize.width, canvasSize.height))
        }
        .frame(width: size, height: size)
        .opacity(pose.opacity)
    }
}

/// The drawing itself, in unit coordinates (0…1 of the frame) scaled by `side`.
enum InkyDrawing {
    /// Nib tip in drawing coordinates (before the inset).
    static let nibTip = CGPoint(x: 0.5, y: 0.965)
    /// The drawing is inset so bounces, tilts and splashes never leave the frame.
    static let inset: CGFloat = 0.92
    /// Where the nib tip lands in the frame (0…1). Callers that stand Inky on a point align this.
    static let nibTipInFrame = CGPoint(x: 0.5, y: 0.5 + (nibTip.y - 0.5) * inset)

    static func draw(_ pose: InkyPose, in frameContext: GraphicsContext, side s: CGFloat) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        var context = frameContext
        context.translateBy(x: s / 2, y: s / 2)
        context.scaleBy(x: inset, y: inset)
        context.translateBy(x: -s / 2, y: -s / 2)

        if let phase = pose.soundWaves { drawSoundWaves(phase, in: context, side: s) }

        var body = context
        let tip = pt(nibTip.x, nibTip.y)
        body.translateBy(x: tip.x + pose.offset.x * s, y: tip.y + pose.offset.y * s)
        body.rotate(by: .degrees(pose.tilt))
        body.scaleBy(x: 1 / sqrt(max(pose.stretch, 0.5)), y: pose.stretch)
        body.translateBy(x: -tip.x, y: -tip.y)

        drawDrop(pose, in: body, side: s)
        drawNib(in: body, side: s)
        drawBarrel(in: body, side: s)
        drawFace(pose, in: body, side: s)

        if let dots = pose.thoughtDots { drawThoughtDots(dots, in: context, side: s) }
        if let phase = pose.splash { drawSplash(phase, in: context, side: s) }
    }

    // MARK: Body

    static func barrelPath(side s: CGFloat) -> Path {
        let k: CGFloat = 0.5523 // cubic approximation of a quarter circle
        let r: CGFloat = 0.23, cx: CGFloat = 0.5, top: CGFloat = 0.14, shoulder: CGFloat = 0.37
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        var p = Path()
        p.move(to: pt(cx - r, shoulder))
        p.addCurve(to: pt(cx, top), control1: pt(cx - r, shoulder - r * k), control2: pt(cx - r * k, top))
        p.addCurve(to: pt(cx + r, shoulder), control1: pt(cx + r * k, top), control2: pt(cx + r, shoulder - r * k))
        // Sides taper slightly toward the grip.
        p.addCurve(to: pt(0.70, 0.67), control1: pt(cx + r, 0.5), control2: pt(0.71, 0.6))
        p.addQuadCurve(to: pt(0.64, 0.725), control: pt(0.695, 0.725))
        p.addLine(to: pt(0.36, 0.725))
        p.addQuadCurve(to: pt(0.30, 0.67), control: pt(0.305, 0.725))
        p.addCurve(to: pt(cx - r, shoulder), control1: pt(0.29, 0.6), control2: pt(cx - r, 0.5))
        p.closeSubpath()
        return p
    }

    static func drawBarrel(in ctx: GraphicsContext, side s: CGFloat) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        ctx.fill(barrelPath(side: s), with: .color(InkyPalette.body))
        // Soft gloss along the left side and on the dome.
        ctx.fill(Path(roundedRect: CGRect(x: 0.312 * s, y: 0.25 * s, width: 0.036 * s, height: 0.27 * s), cornerRadius: 0.018 * s),
                 with: .color(.white.opacity(0.22)))
        ctx.fill(Path(ellipseIn: CGRect(x: 0.355 * s, y: 0.19 * s, width: 0.05 * s, height: 0.036 * s)), with: .color(.white.opacity(0.32)))
        // Grip ring.
        ctx.fill(Path(roundedRect: CGRect(x: 0.335 * s, y: 0.705 * s, width: 0.33 * s, height: 0.06 * s), cornerRadius: 0.025 * s),
                 with: .color(.white.opacity(0.94)))
        ctx.fill(Path(roundedRect: CGRect(x: 0.36 * s, y: 0.728 * s, width: 0.28 * s, height: 0.014 * s), cornerRadius: 0.007 * s),
                 with: .color(InkyPalette.body.opacity(0.22)))
    }

    static func drawNib(in ctx: GraphicsContext, side s: CGFloat) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        var nib = Path()
        nib.move(to: pt(0.355, 0.75))
        nib.addLine(to: pt(0.645, 0.75))
        nib.addCurve(to: pt(nibTip.x, nibTip.y), control1: pt(0.645, 0.84), control2: pt(0.55, 0.9))
        nib.addCurve(to: pt(0.355, 0.75), control1: pt(0.45, 0.9), control2: pt(0.355, 0.84))
        nib.closeSubpath()
        ctx.fill(nib, with: .color(InkyPalette.ink))
        var slit = Path()
        slit.move(to: pt(0.5, 0.83))
        slit.addLine(to: pt(0.5, 0.935))
        ctx.stroke(slit, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 0.014 * s, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: 0.482 * s, y: 0.797 * s, width: 0.036 * s, height: 0.036 * s)), with: .color(.white.opacity(0.85)))
    }

    /// The ink drop on Inky's head, sprouting from the top of the barrel like a cowlick.
    static func drawDrop(_ pose: InkyPose, in context: GraphicsContext, side s: CGFloat) {
        var ctx = context
        ctx.translateBy(x: (0.535 + pose.dropOffset.x) * s, y: (0.165 + pose.dropOffset.y) * s)
        ctx.rotate(by: .degrees(14 + pose.dropTilt))
        ctx.scaleBy(x: s, y: s)
        let r: CGFloat = 0.05
        var drop = Path()
        drop.move(to: CGPoint(x: 0, y: -0.148))
        drop.addCurve(to: CGPoint(x: r, y: -0.06), control1: CGPoint(x: 0.014, y: -0.115), control2: CGPoint(x: r, y: -0.095))
        drop.addCurve(to: CGPoint(x: 0, y: -0.01), control1: CGPoint(x: r, y: -0.03), control2: CGPoint(x: 0.028, y: -0.01))
        drop.addCurve(to: CGPoint(x: -r, y: -0.06), control1: CGPoint(x: -0.028, y: -0.01), control2: CGPoint(x: -r, y: -0.03))
        drop.addCurve(to: CGPoint(x: 0, y: -0.148), control1: CGPoint(x: -r, y: -0.095), control2: CGPoint(x: -0.014, y: -0.115))
        drop.closeSubpath()
        ctx.fill(drop, with: .color(InkyPalette.ink))
        ctx.fill(Path(ellipseIn: CGRect(x: -0.03, y: -0.085, width: 0.018, height: 0.022)), with: .color(.white.opacity(0.7)))
    }

    // MARK: Face

    static let eyeCenters = [CGPoint(x: 0.405, y: 0.385), CGPoint(x: 0.595, y: 0.385)]

    static func drawFace(_ pose: InkyPose, in ctx: GraphicsContext, side s: CGFloat) {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

        // Cheeks.
        for x in [0.34, 0.66] as [CGFloat] {
            ctx.fill(Path(ellipseIn: CGRect(x: (x - 0.04) * s, y: 0.455 * s, width: 0.08 * s, height: 0.042 * s)),
                     with: .color(InkyPalette.blush.opacity(0.5)))
        }

        for center in eyeCenters {
            switch pose.eyes {
            case .happy:
                var arc = Path()
                arc.move(to: pt(center.x - 0.048, center.y + 0.02))
                arc.addQuadCurve(to: pt(center.x + 0.048, center.y + 0.02), control: pt(center.x, center.y - 0.05))
                ctx.stroke(arc, with: .color(.white), style: StrokeStyle(lineWidth: 0.032 * s, lineCap: .round))
            case .open:
                drawEye(at: center, pose: pose, in: ctx, side: s)
            }
        }

        let m = CGPoint(x: 0.5, y: 0.49)
        switch pose.mouth {
        case .smile, .tongue:
            if pose.mouth == .tongue {
                ctx.fill(Path(ellipseIn: CGRect(x: (m.x + 0.006) * s, y: (m.y + 0.008) * s, width: 0.032 * s, height: 0.036 * s)),
                         with: .color(InkyPalette.blush))
            }
            var smile = Path()
            smile.move(to: pt(m.x - 0.036, m.y))
            smile.addQuadCurve(to: pt(m.x + 0.036, m.y), control: pt(m.x, m.y + 0.034))
            ctx.stroke(smile, with: .color(.white), style: StrokeStyle(lineWidth: 0.022 * s, lineCap: .round))
        case .open:
            let depth = 0.022 + 0.05 * pose.mouthOpen
            var mouth = Path()
            mouth.move(to: pt(m.x - 0.042, m.y - 0.006))
            mouth.addLine(to: pt(m.x + 0.042, m.y - 0.006))
            mouth.addCurve(to: pt(m.x - 0.042, m.y - 0.006),
                           control1: pt(m.x + 0.04, m.y + depth), control2: pt(m.x - 0.04, m.y + depth))
            mouth.closeSubpath()
            ctx.fill(mouth, with: .color(InkyPalette.ink))
            if pose.mouthOpen > 0.45 {
                var inner = ctx
                inner.clip(to: mouth)
                inner.fill(Path(ellipseIn: CGRect(x: (m.x - 0.03) * s, y: (m.y + depth * 0.45) * s, width: 0.06 * s, height: 0.05 * s)),
                           with: .color(InkyPalette.blush))
            }
        case .round:
            let h = 0.03 + 0.03 * pose.mouthOpen
            ctx.fill(Path(ellipseIn: CGRect(x: (m.x - 0.022) * s, y: (m.y + 0.008 - h / 2) * s, width: 0.044 * s, height: h * s)),
                     with: .color(InkyPalette.ink))
        }
    }

    static func drawEye(at center: CGPoint, pose: InkyPose, in ctx: GraphicsContext, side s: CGFloat) {
        let w = 0.14 * pose.eyeScale
        let fullHeight = 0.17 * pose.eyeScale
        if pose.eyeOpen < 0.22 {
            var lid = Path()
            lid.move(to: CGPoint(x: (center.x - w * 0.4) * s, y: center.y * s))
            lid.addQuadCurve(to: CGPoint(x: (center.x + w * 0.4) * s, y: center.y * s),
                             control: CGPoint(x: center.x * s, y: (center.y + 0.025) * s))
            ctx.stroke(lid, with: .color(.white), style: StrokeStyle(lineWidth: 0.026 * s, lineCap: .round))
            return
        }
        let h = fullHeight * pose.eyeOpen
        let sclera = Path(ellipseIn: CGRect(x: (center.x - w / 2) * s, y: (center.y - h / 2) * s, width: w * s, height: h * s))
        ctx.fill(sclera, with: .color(.white))
        var inner = ctx
        inner.clip(to: sclera)
        let r = 0.05 * pose.eyeScale
        let pupil = CGPoint(x: center.x + pose.gaze.x * 0.024, y: center.y + 0.01 + pose.gaze.y * 0.03)
        inner.fill(Path(ellipseIn: CGRect(x: (pupil.x - r) * s, y: (pupil.y - r) * s, width: 2 * r * s, height: 2 * r * s)),
                   with: .color(InkyPalette.ink))
        let g = 0.017 * pose.eyeScale
        inner.fill(Path(ellipseIn: CGRect(x: (pupil.x - 0.022 - g) * s, y: (pupil.y - 0.024 - g) * s, width: 2 * g * s, height: 2 * g * s)),
                   with: .color(.white))
    }

    // MARK: Extras

    static func drawThoughtDots(_ dots: [CGFloat], in ctx: GraphicsContext, side s: CGFloat) {
        let spots: [(CGPoint, CGFloat)] = [(CGPoint(x: 0.79, y: 0.30), 0.022), (CGPoint(x: 0.855, y: 0.195), 0.03), (CGPoint(x: 0.92, y: 0.075), 0.04)]
        for (i, (c, r)) in spots.enumerated() where i < dots.count {
            let v = dots[i]
            let rr = r * (0.75 + 0.25 * v)
            ctx.fill(Path(ellipseIn: CGRect(x: (c.x - rr) * s, y: (c.y - rr) * s, width: 2 * rr * s, height: 2 * rr * s)),
                     with: .color(InkyPalette.ink.opacity(Double(0.2 + 0.8 * v))))
        }
    }

    /// Sound arcs closing in on both sides of the head while Inky listens.
    static func drawSoundWaves(_ phase: CGFloat, in ctx: GraphicsContext, side s: CGFloat) {
        let center = CGPoint(x: 0.5, y: 0.37)
        for k in 0..<2 {
            let u = (phase + CGFloat(k) * 0.5).truncatingRemainder(dividingBy: 1)
            let radius = 0.44 - 0.14 * u
            let alpha = Double(sin(u * .pi)) * 0.85
            for base in [Double.pi, 0] {
                var arc = Path()
                for i in 0...8 {
                    let a = base + (Double(i) / 8 - 0.5) * 0.8
                    let p = CGPoint(x: (center.x + radius * CGFloat(cos(a))) * s, y: (center.y + radius * CGFloat(sin(a))) * s)
                    if i == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
                }
                ctx.stroke(arc, with: .color(InkyPalette.body.opacity(alpha)), style: StrokeStyle(lineWidth: 0.03 * s, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Little ink drops popping off Inky's head when happy.
    static func drawSplash(_ phase: CGFloat, in ctx: GraphicsContext, side s: CGFloat) {
        let origin = CGPoint(x: 0.5, y: 0.22)
        let directions = [CGPoint(x: -0.85, y: -0.5), CGPoint(x: 0.9, y: -0.45), CGPoint(x: -0.95, y: 0.25), CGPoint(x: 0.95, y: 0.3)]
        let alpha = Double(sin(phase * .pi))
        for (i, d) in directions.enumerated() {
            let local = min(1, phase * (1 + CGFloat(i % 2) * 0.15))
            let dist = 0.2 + 0.12 * local
            let r = 0.034 * (1 - 0.45 * local)
            let c = CGPoint(x: origin.x + d.x * dist, y: origin.y + d.y * dist + 0.1 * local * local)
            ctx.fill(Path(ellipseIn: CGRect(x: (c.x - r) * s, y: (c.y - r) * s, width: 2 * r * s, height: 2 * r * s)),
                     with: .color(InkyPalette.body.opacity(alpha)))
        }
    }
}
