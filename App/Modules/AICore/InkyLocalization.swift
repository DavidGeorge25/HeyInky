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

            // Grid lines.
            let t = tuning
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
            }
            for y in ys where y > visible.minY + 1e-6 && y < visible.maxY - 1e-6 {
                let label = String(format: "%.\(decimals)f", y) as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: 2, y: py(y) - size.height / 2), withAttributes: attrs)
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
                return RecognizedTextLine(text: candidate.string, box: box)
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
    ) -> InkyRequest {
        InkyRequest(
            question: question,
            images: InkyLocalization.modelImages(pageImage: pageImage, lasso: lassoRegion, lassoPath: lassoPath, annotations: annotations),
            recognizedText: recognizedText,
            lassoRegion: lassoRegion,
            pageAspectRatio: pageAspectRatio,
            notebookTitle: notebookTitle,
            pageAnnotations: annotations,
            history: history
        )
    }
}
