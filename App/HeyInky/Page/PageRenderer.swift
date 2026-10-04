import PDFKit
import PencilKit
import UIKit

/// Draws page content. Used by the on-screen background view, thumbnails, and the
/// snapshot sent to Inky, so all three always agree.
@MainActor
enum PageRenderer {
    struct Layers: OptionSet {
        let rawValue: Int
        static let paper = Layers(rawValue: 1 << 0)
        static let pdf = Layers(rawValue: 1 << 1)
        static let images = Layers(rawValue: 1 << 2)
        static let ink = Layers(rawValue: 1 << 3)
        static let text = Layers(rawValue: 1 << 4)
        static let background: Layers = [.paper, .pdf, .images, .text]
        static let all: Layers = [.paper, .pdf, .images, .text, .ink]
    }

    /// Draws paper, PDF, placed images and text boxes into `rect` of the current context.
    /// `skippingTextBox` is the one being edited on screen (the editor shows it live).
    static func drawBackground(page: Page, notebookID: UUID, store: NotebookStore, in rect: CGRect, context: CGContext, layers: Layers = .background, skippingTextBox: UUID? = nil) {
        UIColor.white.setFill()
        context.fill(rect)

        switch page.background {
        case .paper(let style):
            if layers.contains(.paper) { drawPaper(style, page: page, in: rect, context: context) }
        case .pdf(let asset, let index):
            if layers.contains(.pdf), let pdfPage = store.pdfDocument(asset, in: notebookID)?.page(at: index) {
                drawPDFPage(pdfPage, in: rect, context: context)
            }
        }

        if layers.contains(.images) {
            for placed in page.images {
                store.image(placed.asset, in: notebookID)?.draw(in: placed.frame.cgRect(in: rect.size).offsetBy(dx: rect.minX, dy: rect.minY))
            }
        }

        if layers.contains(.text) {
            let scale = rect.width / page.width
            for box in page.textBoxes where box.id != skippingTextBox {
                let frame = box.frame.cgRect(in: rect.size).offsetBy(dx: rect.minX, dy: rect.minY)
                NSAttributedString(string: box.text, attributes: textAttributes(box, scale: scale))
                    .draw(with: frame, options: [.usesLineFragmentOrigin], context: nil)
            }
        }
    }

    // MARK: Text boxes

    static func font(for box: PageTextBox, scale: CGFloat = 1) -> UIFont {
        let size = box.fontSize * scale
        switch box.style {
        case .typed:
            let base = UIFont.systemFont(ofSize: size, weight: .regular)
            return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        case .handwriting:
            return DrawInk.handwritingFont(size: size)
        }
    }

    static func uiColor(_ color: PageTextBox.Color) -> UIColor {
        switch color {
        case .black: UIColor(white: 0.12, alpha: 1)
        case .blue: UIColor(red: 0.18, green: 0.43, blue: 0.87, alpha: 1)
        case .red: UIColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1)
        case .green: UIColor(red: 0.19, green: 0.62, blue: 0.40, alpha: 1)
        case .indigo: Theme.accentUI
        }
    }

    static func textAttributes(_ box: PageTextBox, scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        [.font: font(for: box, scale: scale), .foregroundColor: uiColor(box.color)]
    }

    /// Height (normalized) the box needs for its text at its width.
    static func textBoxHeight(_ box: PageTextBox, pageSize: CGSize) -> Double {
        let width = box.frame.width * pageSize.width
        let text = box.text.isEmpty ? " " : box.text
        let size = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], attributes: textAttributes(box), context: nil).size
        return (ceil(size.height) + 4) / pageSize.height
    }

    static func drawPaper(_ style: PaperStyle, page: Page, in rect: CGRect, context: CGContext) {
        let scale = rect.width / page.width
        let color = UIColor(red: 0.62, green: 0.70, blue: 0.82, alpha: 0.45)
        context.saveGState()
        defer { context.restoreGState() }
        switch style {
        case .blank:
            break
        case .lined:
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(max(0.5, 0.75 * scale))
            var y = 96.0
            while y < page.height - 24 {
                let py = rect.minY + y * scale
                context.move(to: CGPoint(x: rect.minX, y: py))
                context.addLine(to: CGPoint(x: rect.maxX, y: py))
                y += 32
            }
            context.strokePath()
        case .grid:
            context.setStrokeColor(color.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(max(0.5, 0.5 * scale))
            var v = 24.0
            while v < page.width { context.move(to: CGPoint(x: rect.minX + v * scale, y: rect.minY)); context.addLine(to: CGPoint(x: rect.minX + v * scale, y: rect.maxY)); v += 24 }
            v = 24
            while v < page.height { context.move(to: CGPoint(x: rect.minX, y: rect.minY + v * scale)); context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + v * scale)); v += 24 }
            context.strokePath()
        case .dotted:
            context.setFillColor(color.withAlphaComponent(0.8).cgColor)
            let r = max(0.6, 1.1 * scale)
            var y = 24.0
            while y < page.height {
                var x = 24.0
                while x < page.width {
                    context.fillEllipse(in: CGRect(x: rect.minX + x * scale - r, y: rect.minY + y * scale - r, width: 2 * r, height: 2 * r))
                    x += 24
                }
                y += 24
            }
        }
    }

    static func drawPDFPage(_ pdfPage: PDFPage, in rect: CGRect, context: CGContext) {
        let size = NotebookStore.displaySize(of: pdfPage)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / size.width, y: -rect.height / size.height)
        pdfPage.draw(with: .cropBox, to: context)
        context.restoreGState()
    }

    /// Renders the page to an image `pixelWidth` wide (ink drawn in light mode).
    static func image(page: Page, notebookID: UUID, store: NotebookStore, drawing: PKDrawing?, pixelWidth: CGFloat, layers: Layers = .all) -> UIImage {
        let size = CGSize(width: pixelWidth, height: (pixelWidth * page.height / page.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            drawBackground(page: page, notebookID: notebookID, store: store, in: rect, context: ctx.cgContext, layers: layers)
            if layers.contains(.ink), let drawing, !drawing.strokes.isEmpty {
                let scale = pixelWidth / page.width
                var inkImage = UIImage()
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    inkImage = drawing.image(from: CGRect(origin: .zero, size: page.size), scale: scale)
                }
                inkImage.draw(in: rect)
            }
        }
    }

    /// Text lines from a PDF page with normalized boxes (top-left origin).
    static func pdfTextLines(page: Page, notebookID: UUID, store: NotebookStore) -> [RecognizedTextLine] {
        guard case .pdf(let asset, let index) = page.background,
              let pdfPage = store.pdfDocument(asset, in: notebookID)?.page(at: index),
              pdfPage.rotation % 360 == 0
        else { return [] }
        let box = pdfPage.bounds(for: .cropBox)
        guard let selection = pdfPage.selection(for: box) else { return [] }
        return selection.selectionsByLine().compactMap { line -> RecognizedTextLine? in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let b = line.bounds(for: pdfPage)
            let rect = NormRect(
                x: Double((b.minX - box.minX) / box.width),
                y: 1 - Double((b.maxY - box.minY) / box.height),
                width: Double(b.width / box.width),
                height: Double(b.height / box.height)
            )
            return RecognizedTextLine(text: text, box: rect)
        }
    }
}
