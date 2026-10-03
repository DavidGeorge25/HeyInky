import UIKit
import Vision

/// Prepares what the model sees so its coordinates come back accurate:
/// the rendered page with a light, labeled 0–1 coordinate grid, plus a zoomed crop of the
/// lassoed region (labels still in full-page coordinates). All tuning lives here.
enum InkyLocalization {
    struct Tuning {
        var fullPageLongEdge: CGFloat = 1280
        var cropLongEdge: CGFloat = 1024
        var cropPadding: Double = 0.03
        var gridColor = UIColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)
        var gridLineAlpha: CGFloat = 0.28
        var gridLabelAlpha: CGFloat = 0.8
        var lassoColor = UIColor(red: 0.45, green: 0.25, blue: 0.95, alpha: 0.9)
        var markColor = UIColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 0.85)
        /// Unlabeled lines halfway between labeled ones (0.05 on the full page).
        var minorGridLines = true
        /// Repeat labels along the bottom and right edges (helps for targets far from top/left).
        var labelAllEdges = true
        /// Detect empty answer boxes with Vision and list their exact coordinates.
        var detectBlanks = true
    }

    @MainActor static var tuning = Tuning()

    /// THE localization function. `pageImage` is the page rendered without grid at any
    /// resolution with the page's aspect ratio. Returns images in the order they are sent.
    @MainActor
    static func modelImages(
        pageImage: UIImage, lasso: NormRect?, lassoPath: [NormPoint] = [], annotations: [InkyPageAnnotation] = []
    ) -> [InkyImage] {
        var images: [InkyImage] = []
        let marks = annotations.enumerated().compactMap { index, mark -> (id: String, bounds: NormRect)? in
            guard !mark.isHidden, mark.bounds.width > 0 || mark.bounds.height > 0 else { return nil }
            return ("m\(index + 1)", mark.bounds)
        }
        let full = renderWithGrid(
            source: pageImage, visible: .unit, longEdge: tuning.fullPageLongEdge, step: 0.1,
            lasso: lasso, lassoPath: lassoPath, marks: marks
        )
        if let png = full.pngData() {
            images.append(InkyImage(pngData: png, caption: "Full page with coordinate grid:"))
        }
        if let lasso, lasso.width > 0.01, lasso.height > 0.01 {
            let pad = tuning.cropPadding
            let visible = NormRect(x: lasso.x - pad, y: lasso.y - pad, width: lasso.width + 2 * pad, height: lasso.height + 2 * pad).clamped
            let span = max(visible.width, visible.height)
            let step = span < 0.25 ? 0.02 : (span < 0.5 ? 0.05 : 0.1)
            let crop = renderWithGrid(
                source: pageImage, visible: visible, longEdge: tuning.cropLongEdge, step: step,
                lasso: lasso, lassoPath: lassoPath, marks: marks
            )
            if let png = crop.pngData() {
                images.append(InkyImage(pngData: png, caption: "Zoomed view of the lassoed area (grid labels are full-page coordinates):"))
            }
        }
        return images
    }

    /// Draws `visible` (a normalized sub-rect of the page) scaled to `longEdge`, with grid
    /// lines every `step` labeled in full-page coordinates.
    @MainActor
    static func renderWithGrid(
        source: UIImage, visible: NormRect, longEdge: CGFloat, step: Double,
        lasso: NormRect?, lassoPath: [NormPoint], marks: [(id: String, bounds: NormRect)] = []
    ) -> UIImage {
        let pageSize = source.size
        let visiblePts = visible.cgRect(in: pageSize)
        let scale = longEdge / max(visiblePts.width, visiblePts.height)
        let outSize = CGSize(width: (visiblePts.width * scale).rounded(), height: (visiblePts.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outSize, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: outSize))

            // Map normalized page coords -> output pixels.
            func px(_ nx: Double) -> CGFloat { CGFloat((nx - visible.x) / visible.width) * outSize.width }
            func py(_ ny: Double) -> CGFloat { CGFloat((ny - visible.y) / visible.height) * outSize.height }

            source.draw(in: CGRect(x: px(0), y: py(0), width: px(1) - px(0), height: py(1) - py(0)))

            let t = tuning
            // Minor grid lines (unlabeled), lighter than the labeled ones.
            if t.minorGridLines {
                cg.setStrokeColor(t.gridColor.withAlphaComponent(t.gridLineAlpha * 0.45).cgColor)
                cg.setLineWidth(1)
                let half = step / 2
                var m = (visible.minX / half).rounded(.up) * half
                while m <= visible.maxX + 1e-9 {
                    if abs((m / step).rounded() * step - m) > 1e-6 { cg.move(to: CGPoint(x: px(m), y: 0)); cg.addLine(to: CGPoint(x: px(m), y: outSize.height)) }
                    m += half
                }
                m = (visible.minY / half).rounded(.up) * half
                while m <= visible.maxY + 1e-9 {
                    if abs((m / step).rounded() * step - m) > 1e-6 { cg.move(to: CGPoint(x: 0, y: py(m))); cg.addLine(to: CGPoint(x: outSize.width, y: py(m))) }
                    m += half
                }
                cg.strokePath()
            }

            // Grid lines.
            cg.setStrokeColor(t.gridColor.withAlphaComponent(t.gridLineAlpha).cgColor)
            cg.setLineWidth(1)
            let first = (visible.minX / step).rounded(.up) * step
            var v = first
            var xs: [Double] = []
            while v <= visible.maxX + 1e-9 { xs.append(v); v += step }
            v = (visible.minY / step).rounded(.up) * step
            var ys: [Double] = []
            while v <= visible.maxY + 1e-9 { ys.append(v); v += step }
            for x in xs {
                cg.move(to: CGPoint(x: px(x), y: 0)); cg.addLine(to: CGPoint(x: px(x), y: outSize.height))
            }
            for y in ys {
                cg.move(to: CGPoint(x: 0, y: py(y))); cg.addLine(to: CGPoint(x: outSize.width, y: py(y)))
            }
            cg.strokePath()

            // Labels: x along the top, y down the left side.
            let fontSize = max(11, outSize.width / 70)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: t.gridColor.withAlphaComponent(t.gridLabelAlpha),
                .backgroundColor: UIColor.white.withAlphaComponent(0.75),
            ]
            let decimals = step < 0.05 ? 2 : (step < 0.1 ? 2 : 1)
            for x in xs where x > visible.minX + 1e-6 && x < visible.maxX - 1e-6 {
                let label = String(format: "%.\(decimals)f", x) as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: px(x) - size.width / 2, y: 2), withAttributes: attrs)
                if t.labelAllEdges {
                    label.draw(at: CGPoint(x: px(x) - size.width / 2, y: outSize.height - size.height - 2), withAttributes: attrs)
                }
            }
            for y in ys where y > visible.minY + 1e-6 && y < visible.maxY - 1e-6 {
                let label = String(format: "%.\(decimals)f", y) as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: 2, y: py(y) - size.height / 2), withAttributes: attrs)
                if t.labelAllEdges {
                    label.draw(at: CGPoint(x: outSize.width - size.width - 2, y: py(y) - size.height / 2), withAttributes: attrs)
                }
            }

            // Existing Inky marks: thin outline + id tag, so the model can refer to them.
            if !marks.isEmpty {
                let tagAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize * 0.9, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .backgroundColor: t.markColor,
                ]
                for mark in marks {
                    let b = mark.bounds
                    let rect = CGRect(x: px(b.minX), y: py(b.minY), width: max(4, px(b.maxX) - px(b.minX)), height: max(4, py(b.maxY) - py(b.minY)))
                    cg.setStrokeColor(t.markColor.cgColor)
                    cg.setLineWidth(max(1.5, outSize.width / 600))
                    cg.setLineDash(phase: 0, lengths: [4, 3])
                    cg.stroke(rect)
                    let tag = " \(mark.id) " as NSString
                    let size = tag.size(withAttributes: tagAttrs)
                    tag.draw(at: CGPoint(x: rect.minX, y: max(0, rect.minY - size.height)), withAttributes: tagAttrs)
                }
                cg.setLineDash(phase: 0, lengths: [])
            }

            // Lasso outline.
            if lasso != nil || !lassoPath.isEmpty {
                cg.setStrokeColor(t.lassoColor.cgColor)
                cg.setLineWidth(max(2, outSize.width / 400))
                cg.setLineDash(phase: 0, lengths: [8, 6])
                if lassoPath.count > 2 {
                    cg.move(to: CGPoint(x: px(lassoPath[0].x), y: py(lassoPath[0].y)))
                    for p in lassoPath.dropFirst() { cg.addLine(to: CGPoint(x: px(p.x), y: py(p.y))) }
                    cg.closePath()
                } else if let lasso {
                    cg.addRect(CGRect(x: px(lasso.minX), y: py(lasso.minY), width: px(lasso.maxX) - px(lasso.minX), height: py(lasso.maxY) - py(lasso.minY)))
                }
                cg.strokePath()
            }
        }
    }

    /// Empty rectangles (answer boxes) on the page, normalized top-left origin. Rectangles that
    /// contain recognized text, or that are tiny / huge, are dropped. Exact boxes beat estimating
    /// a blank's position from the grid.
    static func detectBlanks(in image: CGImage, text: [RecognizedTextLine]) async -> [NormRect] {
        await Task.detached(priority: .userInitiated) {
            guard let ink = InkMask(image: image, maxDimension: 1700, threshold: 175) else { return [] }
            var blanks: [NormRect] = []
            for r in ink.components(minPixels: 60) {
                let area = r.width * r.height
                if r.width > 0.03, r.height > 0.015, area < 0.08, r.height < 0.15 {
                    // Box: an inked outline around an empty inside, with no recognized text in it.
                    guard ink.borderCoverage(r) > 0.8,
                          ink.density(r.insetBy(dx: r.width * 0.15, dy: r.height * 0.22)) < 0.004,
                          !text.contains(where: { $0.box.overlapFraction(with: r) > 0.5 })
                    else { continue }
                    blanks.append(r)
                } else if r.width > 0.08, r.height < 0.008 {
                    // Underline blank "_____": a lone horizontal line that continues a text line.
                    let slot = NormRect(x: r.x, y: r.y - 0.035, width: r.width, height: 0.035 + r.height)
                    let follows = text.contains { line in
                        line.box.maxX <= r.minX + 0.01 && r.minX - line.box.maxX < 0.06
                            && line.box.maxY > slot.minY && line.box.minY < r.maxY
                    }
                    guard follows, ink.density(slot.insetBy(dx: 0.004, dy: 0.004)) < 0.004 else { continue }
                    blanks.append(slot)
                }
            }
            return blanks.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        }.value
    }

    /// On-device OCR (printed + handwriting). Boxes are normalized, top-left origin.
    static func recognizeText(in image: CGImage) async -> [RecognizedTextLine] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            return (request.results ?? []).compactMap { observation -> RecognizedTextLine? in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence > 0.3 else { return nil }
                let b = observation.boundingBox
                let box = NormRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                // Per-word left edges (Vision gives exact boxes for substrings).
                let string = candidate.string
                var starts: [Double] = []
                var index = string.startIndex
                while index < string.endIndex {
                    guard let start = string[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
                    let end = string[start...].firstIndex(where: \.isWhitespace) ?? string.endIndex
                    if let wordBox = try? candidate.boundingBox(for: start..<end)?.boundingBox {
                        starts.append(wordBox.minX)
                    }
                    index = end
                }
                let wordCount = string.split(whereSeparator: \.isWhitespace).count
                return RecognizedTextLine(text: string, box: box, wordStarts: starts.count == wordCount ? starts : nil)
            }
            .sorted { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) }
        }.value
    }
}

/// One call that turns what the app knows about the page into a model request
/// (the "context packet"): grid-overlaid page image, lasso crop, text with boxes,
/// existing Inky marks, and the conversation so far.
enum InkyContextBuilder {
    @MainActor
    static func makeRequest(
        question: String,
        pageImage: UIImage,
        recognizedText: [RecognizedTextLine],
        lassoRegion: NormRect?,
        lassoPath: [NormPoint] = [],
        pageAspectRatio: Double,
        notebookTitle: String?,
        annotations: [InkyPageAnnotation] = [],
        history: [InkyTurn] = []
    ) async -> InkyRequest {
        var blanks: [NormRect] = []
        if InkyLocalization.tuning.detectBlanks, let cg = pageImage.cgImage {
            blanks = await InkyLocalization.detectBlanks(in: cg, text: recognizedText)
        }
        return InkyRequest(
            question: question,
            images: InkyLocalization.modelImages(pageImage: pageImage, lasso: lassoRegion, lassoPath: lassoPath, annotations: annotations),
            recognizedText: recognizedText,
            lassoRegion: lassoRegion,
            pageAspectRatio: pageAspectRatio,
            notebookTitle: notebookTitle,
            pageAnnotations: annotations,
            history: history,
            blanks: blanks
        )
    }
}

/// Binary "dark ink" mask of a page: keeps pen strokes and printed text, drops light paper
/// lines/grids and soft colors, so shape detection sees what the student drew.
struct InkMask: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]  // 1 = ink

    init?(image: CGImage, maxDimension: Int, threshold: Int = 150) {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var gray = [UInt8](repeating: 255, count: w * h)
        let ok = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w
        height = h
        pixels = gray.map { Int($0) < threshold ? 1 : 0 }
    }

    /// Black-on-white image of the mask (for Vision).
    func cgImage() -> CGImage? {
        let bytes = pixels.map { $0 == 1 ? UInt8(0) : UInt8(255) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // Row 0 of `pixels` is the top of the page (CGContext draws with a flipped bitmap origin
    // for gray contexts created this way: data starts at the top row).
    func ink(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return pixels[y * width + x] == 1
    }

    /// Bounding boxes (normalized) of 8-connected ink components with at least `minPixels` pixels.
    func components(minPixels: Int) -> [NormRect] {
        var seen = [Bool](repeating: false, count: pixels.count)
        var boxes: [NormRect] = []
        var stack: [Int] = []
        for start in 0..<pixels.count where pixels[start] == 1 && !seen[start] {
            seen[start] = true
            stack.append(start)
            var count = 0
            var minX = width, minY = height, maxX = 0, maxY = 0
            while let i = stack.popLast() {
                count += 1
                let x = i % width, y = i / width
                minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
                minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let j = ny * width + nx
                        if pixels[j] == 1 && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            guard count >= minPixels else { continue }
            boxes.append(NormRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                                  width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height)))
        }
        return boxes
    }

    /// Fraction of ink pixels inside a normalized rect.
    func density(_ r: NormRect) -> Double {
        let x0 = Int(r.minX * Double(width)), x1 = Int(r.maxX * Double(width))
        let y0 = Int(r.minY * Double(height)), y1 = Int(r.maxY * Double(height))
        guard x1 > x0, y1 > y0 else { return 0 }
        var count = 0
        for y in y0..<y1 { for x in x0..<x1 where ink(x, y) { count += 1 } }
        return Double(count) / Double((x1 - x0) * (y1 - y0))
    }

    /// Fraction of points along the rect's outline that have ink within a few pixels.
    func borderCoverage(_ r: NormRect, samplesPerSide: Int = 40, slack: Int = 3) -> Double {
        func hit(_ nx: Double, _ ny: Double) -> Bool {
            let cx = Int(nx * Double(width)), cy = Int(ny * Double(height))
            for dy in -slack...slack { for dx in -slack...slack where ink(cx + dx, cy + dy) { return true } }
            return false
        }
        var hits = 0
        for i in 0..<samplesPerSide {
            let f = (Double(i) + 0.5) / Double(samplesPerSide)
            if hit(r.minX + f * r.width, r.minY) { hits += 1 }
            if hit(r.minX + f * r.width, r.maxY) { hits += 1 }
            if hit(r.minX, r.minY + f * r.height) { hits += 1 }
            if hit(r.maxX, r.minY + f * r.height) { hits += 1 }
        }
        return Double(hits) / Double(4 * samplesPerSide)
    }
}
