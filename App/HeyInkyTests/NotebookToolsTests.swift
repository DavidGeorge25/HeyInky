import CoreText
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import HeyInky

/// Everyday notebook tools: shape correction, text boxes, handwriting → text, PDF export.
@MainActor
@Suite("Notebook tools")
struct NotebookToolsTests {
    let pageSize = CGSize(width: 816, height: 1056)

    func makeEditor() -> PageEditorModel {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "Tools", paper: .blank)
        return PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
    }

    /// A hand-drawn-ish stroke through `points`; `holdAtEnd` adds the pen resting still.
    func stroke(_ points: [CGPoint], holdAtEnd: Bool = false, wobble: CGFloat = 1.5) -> PKStroke {
        var samples = DrawInk.densify(points, spacing: 3).enumerated().map { i, p in
            CGPoint(x: p.x + sin(CGFloat(i) * 0.7) * wobble, y: p.y + cos(CGFloat(i) * 0.9) * wobble)
        }
        var times = samples.indices.map { Double($0) * 0.01 }
        if holdAtEnd, let last = samples.last, let t = times.last {
            for k in 1...10 { samples.append(CGPoint(x: last.x + 0.3, y: last.y)); times.append(t + Double(k) * 0.06) }
        }
        let path = PKStrokePath(controlPoints: zip(samples, times).map {
            PKStrokePoint(location: $0.0, timeOffset: $0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: .now)
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    func circle(center: CGPoint, rx: CGFloat, ry: CGFloat) -> [CGPoint] {
        (0...60).map { i in
            let t = CGFloat(i) / 60 * 2 * .pi
            return CGPoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t))
        }
    }

    // MARK: Shapes

    @Test func recognizesLinesCirclesEllipsesAndPolygons() throws {
        func noisy(_ pts: [CGPoint]) -> [CGPoint] {
            DrawInk.densify(pts, spacing: 3).enumerated().map { i, p -> CGPoint in
                let dx: CGFloat = sin(CGFloat(i)) * 1.5
                let dy: CGFloat = cos(CGFloat(i) * 1.3) * 1.5
                return CGPoint(x: p.x + dx, y: p.y + dy)
            }
        }

        guard case .line(let a, let b) = ShapeRecognizer.recognize(noisy([CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 207)])) else { Issue.record("line"); return }
        #expect(abs(a.y - b.y) < 0.01, "a nearly-horizontal line snaps level")

        guard case .ellipse(let c) = ShapeRecognizer.recognize(noisy(circle(center: CGPoint(x: 300, y: 300), rx: 80, ry: 76))) else { Issue.record("circle"); return }
        #expect(abs(c.width - c.height) < 0.01, "near-round → circle")
        #expect(abs(c.midX - 300) < 4 && abs(c.width - 156) < 12)

        guard case .ellipse(let e) = ShapeRecognizer.recognize(noisy(circle(center: CGPoint(x: 300, y: 300), rx: 120, ry: 60))) else { Issue.record("ellipse"); return }
        #expect(e.width > e.height * 1.6)

        let rect: [CGPoint] = [.init(x: 100, y: 100), .init(x: 300, y: 104), .init(x: 298, y: 220), .init(x: 102, y: 216), .init(x: 100, y: 102)]
        guard case .polygon(let r) = ShapeRecognizer.recognize(noisy(rect)) else { Issue.record("rectangle"); return }
        #expect(r.count == 4)
        #expect(abs(r[0].y - r[1].y) < 0.01 && abs(r[1].x - r[2].x) < 0.01, "axis-aligned rectangle")

        let triangle: [CGPoint] = [.init(x: 200, y: 100), .init(x: 300, y: 280), .init(x: 100, y: 280), .init(x: 200, y: 102)]
        guard case .polygon(let t) = ShapeRecognizer.recognize(noisy(triangle)) else { Issue.record("triangle"); return }
        #expect(t.count == 3)

        // Handwriting-like scribbles are left alone.
        let scribble: [CGPoint] = (0..<40).map { i -> CGPoint in
            let x: CGFloat = 100 + CGFloat(i) * 6
            let zig: CGFloat = i % 2 == 0 ? 0 : 25
            return CGPoint(x: x, y: 200 + zig + CGFloat(i % 5) * 4)
        }
        #expect(ShapeRecognizer.recognize(scribble) == nil)
    }

    @Test func onlyStrokesEndingWithAHoldAreCorrected() async throws {
        #expect(!ShapeRecognizer.endsWithHold(stroke([CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 105)])))
        let held = stroke([CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 105)], holdAtEnd: true)
        #expect(ShapeRecognizer.endsWithHold(held))

        let editor = makeEditor()
        PageEditorModel.shapeCorrectionEnabled = true
        editor.drawingDidChange(PKDrawing(strokes: [held]))
        try await Task.sleep(for: .milliseconds(50))
        let corrected = try #require(editor.drawing.strokes.first)
        let points = corrected.path.map(\.location)
        #expect(points.allSatisfy { abs($0.y - points[0].y) < 0.01 }, "replaced by a clean level line")
        #expect(corrected.ink.inkType == .pen, "same ink")

        // A plain stroke stays as drawn.
        let plain = stroke([CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 305)])
        editor.drawingDidChange(PKDrawing(strokes: [corrected, plain]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(editor.drawing.strokes[1].path.count == plain.path.count)
    }

    // MARK: Text boxes

    @Test func textToolCreatesEditsSavesAndUndoes() throws {
        let editor = makeEditor()
        editor.isTextMode = true
        editor.textTap(at: NormPoint(x: 0.2, y: 0.3))
        let id = try #require(editor.editingTextBoxID)
        var box = try #require(editor.page.textBoxes.first)
        box.text = "Le Chatelier's principle\nshifts to oppose a change"
        editor.updateTextBox(box)
        let twoLines = try #require(editor.page.textBoxes.first).frame.height
        #expect(twoLines > 0.035, "height follows the text")
        editor.endTextEditing()
        #expect(editor.editingTextBoxID == nil)
        // Saved.
        let saved = try #require(editor.store.notebook(id: editor.notebookID)?.pages[0].textBoxes.first)
        #expect(saved.id == id && saved.text.hasPrefix("Le Chatelier"))
        // Tapping it edits it again rather than making another.
        editor.textTap(at: NormPoint(x: 0.21, y: 0.3 + twoLines / 2))
        #expect(editor.editingTextBoxID == id)
        editor.endTextEditing()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        editor.undo()
        #expect(editor.page.textBoxes.isEmpty, "undo removes the typed box")
    }

    @Test func emptyTextBoxesDisappearAndOldPagesStillLoad() throws {
        let editor = makeEditor()
        editor.textTap(at: NormPoint(x: 0.5, y: 0.5))
        editor.endTextEditing()
        #expect(editor.page.textBoxes.isEmpty)

        let json = #"{"id":"\#(UUID())","width":816,"height":1056,"background":{"paper":{"_0":"lined"}},"images":[]}"#
        let page = try JSONDecoder().decode(Page.self, from: Data(json.utf8))
        #expect(page.textBoxes.isEmpty)
    }

    @Test func textBoxesAreDrawnAndSelectable() throws {
        let editor = makeEditor()
        editor.textTap(at: NormPoint(x: 0.1, y: 0.1))
        var box = try #require(editor.page.textBoxes.first)
        box.text = "Hello"
        box.fontSize = 40
        editor.updateTextBox(box)
        editor.endTextEditing()
        let image = PageRenderer.image(page: editor.page, notebookID: editor.notebookID, store: editor.store, drawing: nil, pixelWidth: 816)
        let frame = editor.page.textBoxes[0].frame.cgRect(in: pageSize)
        var dark = 0
        for x in stride(from: frame.minX, to: frame.maxX, by: 2) {
            for y in stride(from: frame.minY, to: frame.maxY, by: 2) where image.pixel(at: CGPoint(x: x, y: y)).r < 0.5 { dark += 1 }
        }
        #expect(dark > 20, "text is drawn on the page")

        // Select it, scale it up: the font grows with it.
        editor.isSelectMode = true
        editor.select(at: frame.center.normalized(in: pageSize))
        #expect(editor.selection?.textBoxIDs == [box.id])
        editor.beginSelectionTransform()
        editor.updateSelectionTransform(translation: NormPoint(x: 0, y: 0), scale: 1.5)
        editor.endSelectionTransform()
        #expect(abs(editor.page.textBoxes[0].fontSize - 60) < 0.01)
        editor.copySelection()
        editor.paste(at: NormPoint(x: 0.5, y: 0.6))
        #expect(editor.page.textBoxes.count == 2)
    }

    // MARK: Handwriting → text

    /// "HELLO" as pen strokes tracing a font's outlines: real, legible ink.
    func writtenStrokes(_ text: String, at origin: CGPoint, size: CGFloat) -> [PKStroke] {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var strokes: [PKStroke] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                var current: [CGPoint] = []
                func flush() { if current.count > 1 { strokes.append(stroke(current, wobble: 0)) }; current = [] }
                path.applyWithBlock { element in
                    let e = element.pointee
                    let map = { (p: CGPoint) in CGPoint(x: origin.x + position.x + p.x, y: origin.y - p.y) }
                    switch e.type {
                    case .moveToPoint: flush(); current = [map(e.points[0])]
                    case .addLineToPoint: current.append(map(e.points[0]))
                    case .addQuadCurveToPoint: current.append(map(e.points[1]))
                    case .addCurveToPoint: current.append(map(e.points[2]))
                    case .closeSubpath: if let f = current.first { current.append(f) }; flush()
                    @unknown default: break
                    }
                }
                flush()
            }
        }
        return strokes
    }

    @Test func convertsSelectedHandwritingToATextBox() async throws {
        let editor = makeEditor()
        let strokes = writtenStrokes("HELLO", at: CGPoint(x: 120, y: 300), size: 60)
        editor.drawingDidChange(PKDrawing(strokes: strokes))
        editor.isSelectMode = true
        editor.select(lasso: [NormPoint(x: 0.1, y: 0.2), NormPoint(x: 0.6, y: 0.2), NormPoint(x: 0.6, y: 0.32), NormPoint(x: 0.1, y: 0.32)])
        #expect(editor.selection?.strokeIndices.count == strokes.count)
        let ok = await editor.convertSelectedInkToText()
        #expect(ok)
        #expect(editor.drawing.strokes.isEmpty, "the ink became text")
        let box = try #require(editor.page.textBoxes.first)
        #expect(box.text.uppercased().contains("HELLO"), "read \(box.text)")
        try await Task.sleep(for: .milliseconds(20))   // end the undo group's event
        editor.undo()
        #expect(editor.drawing.strokes.count == strokes.count && editor.page.textBoxes.isEmpty)
    }

    // MARK: Export

    @Test func exportsEveryPageAsPDFWithTextAndInky() throws {
        let editor = makeEditor()
        let store = editor.store
        editor.textTap(at: NormPoint(x: 0.1, y: 0.1))
        var box = try #require(editor.page.textBoxes.first)
        box.text = "Exported notes"
        editor.updateTextBox(box)
        editor.endTextEditing()
        editor.addAnnotation(.highlight(HighlightAction(region: NormRect(x: 0.1, y: 0.1, width: 0.3, height: 0.04), color: .yellow, note: nil)), question: nil)
        _ = store.addPage(to: editor.notebookID, background: .paper(.grid))
        let notebook = try #require(store.notebook(id: editor.notebookID))

        let url = try NotebookExporter.pdf(notebook: notebook, store: store)
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 0)?.string?.contains("Exported notes") == true, "typed text stays real text")
        #expect(NotebookExporter.inkyLayerImage(store.annotations(for: notebook.pages[0].id, in: notebook.id), pageSize: pageSize) != nil)
    }
}

extension CGPoint {
    func normalized(in size: CGSize) -> NormPoint { NormPoint(x: x / size.width, y: y / size.height) }
}
