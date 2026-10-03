import SwiftUI

/// Native drawing of a graph scene with SwiftUI `Canvas`. Used where a live web view can't be:
/// flattening a card into a page image, snapshot tests, and as the placeholder while the
/// board loads. Visual language matches the JSXGraph board (inky-graph.js).
struct GraphPlotView: View {
    let document: GraphDocument
    let scene: GraphScene
    /// Draw a legend and parameter values (for flattened images that must stand alone).
    var standalone = false

    var body: some View {
        Canvas { context, size in
            GraphPlotRenderer(document: document, scene: scene, size: size, standalone: standalone).draw(in: &context)
        }
        .background(GraphTheme.color(scene.theme.background))
    }

    /// Renders to an image at `scale` pixels per point.
    @MainActor
    static func image(document: GraphDocument, scene: GraphScene, size: CGSize, scale: CGFloat = 3, standalone: Bool = true) -> UIImage? {
        let renderer = ImageRenderer(content: GraphPlotView(document: document, scene: scene, standalone: standalone)
            .frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

struct GraphPlotRenderer {
    let document: GraphDocument
    let scene: GraphScene
    let size: CGSize
    let standalone: Bool

    private var s: CGFloat { CGFloat(scene.scale) }
    private var v: GraphScene.View { scene.view }
    private func color(_ css: String) -> Color { GraphTheme.color(css) }

    func px(_ x: Double) -> CGFloat { CGFloat((x - v.xMin) / (v.xMax - v.xMin)) * size.width }
    func py(_ y: Double) -> CGFloat { size.height - CGFloat((y - v.yMin) / (v.yMax - v.yMin)) * size.height }
    func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: px(x), y: py(y)) }

    func draw(in context: inout GraphicsContext) {
        guard v.xMax > v.xMin, v.yMax > v.yMin, size.width > 1, size.height > 1 else { return }
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        drawGridAndAxes(&context)
        if scene.options.asymptotes { drawAsymptotes(&context) }
        drawCurves(&context)
        if scene.options.features { drawFeatures(&context) }
        drawPointsAndLabels(&context)
        if standalone { drawLegend(&context) }
    }

    // MARK: Grid and axes

    /// 1, 2 or 5 × 10ⁿ so that ticks are at least `minPixels` apart.
    static func tickStep(span: Double, pixels: CGFloat, minPixels: CGFloat) -> Double {
        guard span > 0, pixels > 0 else { return 1 }
        let raw = span * Double(minPixels / pixels)
        let magnitude = pow(10, floor(log10(raw)))
        for m in [1.0, 2, 5, 10] where m * magnitude >= raw { return m * magnitude }
        return 10 * magnitude
    }

    private func ticks(from lo: Double, to hi: Double, step: Double) -> [Double] {
        var out: [Double] = []
        var t = (lo / step).rounded(.up) * step
        while t <= hi, out.count < 200 { out.append(abs(t) < step * 1e-9 ? 0 : t); t += step }
        return out
    }

    private func drawGridAndAxes(_ context: inout GraphicsContext) {
        let theme = scene.theme
        let xStep = Self.tickStep(span: v.xMax - v.xMin, pixels: size.width, minPixels: 46 * s)
        let yStep = Self.tickStep(span: v.yMax - v.yMin, pixels: size.height, minPixels: 34 * s)
        let xTicks = ticks(from: v.xMin, to: v.xMax, step: xStep)
        let yTicks = ticks(from: v.yMin, to: v.yMax, step: yStep)

        var grid = Path()
        for x in xTicks { grid.move(to: CGPoint(x: px(x), y: 0)); grid.addLine(to: CGPoint(x: px(x), y: size.height)) }
        for y in yTicks { grid.move(to: CGPoint(x: 0, y: py(y))); grid.addLine(to: CGPoint(x: size.width, y: py(y))) }
        context.stroke(grid, with: .color(color(theme.grid)), lineWidth: 1)

        // Axes stick to the edge when 0 is out of view, like JSXGraph's sticky axes.
        let axisY = min(max(py(0), 0), size.height - 1)
        let axisX = min(max(px(0), 0), size.width - 1)
        var axes = Path()
        axes.move(to: CGPoint(x: 0, y: axisY)); axes.addLine(to: CGPoint(x: size.width, y: axisY))
        axes.move(to: CGPoint(x: axisX, y: 0)); axes.addLine(to: CGPoint(x: axisX, y: size.height))
        context.stroke(axes, with: .color(color(theme.axis)), lineWidth: max(1, s))

        let font = Font.system(size: 10 * s, design: .rounded)
        let textColor = color(theme.text)
        let labelBelow = axisY < size.height - 16 * s
        for x in xTicks where abs(x) > xStep * 1e-9 {
            let text = Text(GraphFormat.number(x)).font(font).foregroundStyle(textColor)
            context.draw(text, at: CGPoint(x: px(x), y: labelBelow ? axisY + 3 * s : axisY - 3 * s), anchor: labelBelow ? .top : .bottom)
        }
        let labelLeft = axisX > 24 * s
        for y in yTicks where abs(y) > yStep * 1e-9 {
            let text = Text(GraphFormat.number(y)).font(font).foregroundStyle(textColor)
            context.draw(text, at: CGPoint(x: labelLeft ? axisX - 4 * s : axisX + 4 * s, y: py(y)), anchor: labelLeft ? .trailing : .leading)
        }

        let nameFont = Font.system(size: 12 * s, weight: .medium, design: .rounded)
        context.draw(Text(scene.axes.x).font(nameFont).foregroundStyle(textColor),
                     at: CGPoint(x: size.width - 6 * s, y: axisY - 4 * s), anchor: .bottomTrailing)
        context.draw(Text(scene.axes.y).font(nameFont).foregroundStyle(textColor),
                     at: CGPoint(x: axisX + 8 * s, y: 4 * s), anchor: .topLeading)
    }

    // MARK: Curves

    private func drawCurves(_ context: inout GraphicsContext) {
        let poles = scene.asymptotes.filter { $0.kind == .vertical }.map(\.value)
        let ySpan = v.yMax - v.yMin, yMid = (v.yMax + v.yMin) / 2
        let count = max(Int(size.width * 1.5), 64)
        for function in scene.functions {
            guard let f = document.evaluator(at: function.index) else { continue }
            var path = Path()
            var previous: (x: Double, y: Double)?
            for k in 0...count {
                let x = v.xMin + (v.xMax - v.xMin) * Double(k) / Double(count)
                let y = f(x)
                guard y.isFinite else { previous = nil; continue }
                // Clamp far-off values so the path stays numerically sane; clipping hides the rest.
                let yc = min(max(y, v.yMin - ySpan * 20), v.yMax + ySpan * 20)
                if let p = previous {
                    let crossesPole = poles.contains { (p.x < $0) != (x < $0) }
                    let jumps = (p.y - yMid).sign != (yc - yMid).sign && abs(yc - p.y) > ySpan * 1.5
                    if crossesPole || jumps { path.move(to: point(x, yc)) } else { path.addLine(to: point(x, yc)) }
                } else {
                    path.move(to: point(x, yc))
                }
                previous = (x, yc)
            }
            context.stroke(path, with: .color(color(function.color)),
                           style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawAsymptotes(_ context: inout GraphicsContext) {
        let font = Font.system(size: 10 * s, design: .rounded)
        for a in scene.asymptotes {
            let c = color(a.color ?? scene.theme.muted)
            var path = Path()
            let labelAt: CGPoint
            let anchor: UnitPoint
            switch a.kind {
            case .vertical:
                path.move(to: point(a.value, v.yMin)); path.addLine(to: point(a.value, v.yMax))
                labelAt = CGPoint(x: px(a.value) + 4 * s, y: py(v.yMax - (v.yMax - v.yMin) * 0.06)); anchor = .bottomLeading
            case .horizontal:
                path.move(to: point(v.xMin, a.value)); path.addLine(to: point(v.xMax, a.value))
                labelAt = CGPoint(x: px(v.xMax - (v.xMax - v.xMin) * 0.02), y: py(a.value) - 3 * s); anchor = .bottomTrailing
            case .oblique:
                path.move(to: point(v.xMin, a.slope * v.xMin + a.value)); path.addLine(to: point(v.xMax, a.slope * v.xMax + a.value))
                let lx = v.xMax - (v.xMax - v.xMin) * 0.2
                labelAt = CGPoint(x: px(lx) + 4 * s, y: py(a.slope * lx + a.value) - 3 * s); anchor = .bottomLeading
            }
            context.stroke(path, with: .color(c.opacity(0.85)), style: StrokeStyle(lineWidth: 1.3 * s, dash: [5 * s, 4 * s]))
            context.draw(Text(a.label).font(font).foregroundStyle(c), at: labelAt, anchor: anchor)
        }
    }

    private func drawFeatures(_ context: inout GraphicsContext) {
        let showLabels = scene.features.count <= 6
        let font = Font.system(size: 10 * s, design: .rounded)
        for feature in scene.features {
            let c = color(scene.functions.indices.contains(feature.function) ? scene.functions[feature.function].color : scene.theme.axis)
            let r = (feature.kind == .maximum || feature.kind == .minimum ? 3.2 : 2.6) * s
            let center = point(feature.x, feature.y)
            let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            context.fill(dot, with: .color(feature.kind == .inflection ? color(scene.theme.background) : c))
            context.stroke(dot, with: .color(c), lineWidth: 1.4 * s)
            if showLabels {
                context.draw(Text(feature.label).font(font).foregroundStyle(color(scene.theme.text)),
                             at: CGPoint(x: center.x + 6 * s, y: center.y - 4 * s), anchor: .bottomLeading)
            }
        }
    }

    private func drawPointsAndLabels(_ context: inout GraphicsContext) {
        let theme = scene.theme
        for p in scene.points {
            let r = (p.draggable ? 5 : 3.5) * s
            let c = point(p.x, p.y)
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.fill(dot, with: .color(color(theme.accent)))
            context.stroke(dot, with: .color(color(theme.background)), lineWidth: 1.5 * s)
            if let label = p.label, !label.isEmpty {
                context.draw(Text(label).font(.system(size: 11 * s, design: .rounded)).foregroundStyle(color(theme.text)),
                             at: CGPoint(x: c.x + 8 * s, y: c.y - 6 * s), anchor: .bottomLeading)
            }
        }
        for l in scene.labels {
            context.draw(Text(l.text).font(.system(size: 11 * s, design: .rounded)).foregroundStyle(color(theme.text)),
                         at: point(l.x, l.y), anchor: .leading)
        }
    }

    // MARK: Legend (standalone images)

    private func drawLegend(_ context: inout GraphicsContext) {
        var lines: [(String, String)] = scene.functions.map { f in
            (f.color, "\(f.label) = \(GraphExpressionDisplay.pretty(document.spec.functions[f.index].expression))")
        }
        if !document.spec.params.isEmpty {
            let values = document.spec.params.map { "\($0.name) = \(GraphFormat.number($0.value))" }.joined(separator: ",  ")
            lines.append((scene.theme.text, values))
        }
        let font = Font.system(size: 10.5 * s, weight: .medium, design: .rounded)
        var y = 8 * s
        let x = min(px(0) > size.width * 0.4 ? 10 * s : max(px(0) + 14 * s, 10 * s), size.width * 0.5)
        for (css, text) in lines {
            let resolved = context.resolve(Text(text).font(font).foregroundStyle(color(css)))
            let textSize = resolved.measure(in: CGSize(width: size.width - x - 10 * s, height: 40 * s))
            let box = CGRect(x: x - 4 * s, y: y - 2 * s, width: textSize.width + 8 * s, height: textSize.height + 4 * s)
            context.fill(Path(roundedRect: box, cornerRadius: 4 * s), with: .color(color(scene.theme.background).opacity(0.85)))
            context.draw(resolved, in: CGRect(x: x, y: y, width: textSize.width, height: textSize.height))
            y += textSize.height + 5 * s
        }
    }
}

/// Friendlier rendering of an expression for chips and legends: `Math.` dropped, `*` as `·`.
enum GraphExpressionDisplay {
    static func pretty(_ expression: String) -> String {
        expression
            .replacingOccurrences(of: "Math.PI", with: "π")
            .replacingOccurrences(of: "Math.", with: "")
            .replacingOccurrences(of: "**", with: "^")
            .replacingOccurrences(of: "*", with: "·")
    }
}
