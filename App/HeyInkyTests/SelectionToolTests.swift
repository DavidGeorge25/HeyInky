import PencilKit
import Testing
import UIKit
@testable import HeyInky

/// The Select tool: lasso/tap selection of ink, images and Inky marks; move, scale, copy, paste,
/// duplicate, delete, undo; "Make it my ink"; asking Inky about a selection.
@MainActor
@Suite("Select tool")
struct SelectionToolTests {
    let pageSize = CGSize(width: 816, height: 1056)

    func makeEditor() -> PageEditorModel {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "Select", paper: .blank)
        let editor = PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
        editor.isSelectMode = true
        return editor
    }

    func stroke(from a: CGPoint, to b: CGPoint) -> PKStroke {
        PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: DrawInk.densify([a, b], spacing: 3).enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: .now))
    }

    /// A rectangle lasso in normalized coordinates.
    func lasso(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [NormPoint] {
        [NormPoint(x: x, y: y), NormPoint(x: x + w, y: y), NormPoint(x: x + w, y: y + h), NormPoint(x: x, y: y + h)]
    }

    func endEvent() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    /// Ink at top-left, a star in the middle, ink far away.
    func populated() -> PageEditorModel {
        let editor = makeEditor()
        editor.drawingDidChange(PKDrawing(strokes: [
            stroke(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 120)),
            stroke(from: CGPoint(x: 600, y: 900), to: CGPoint(x: 700, y: 950)),
        ]))
        editor.addAnnotation(.star(StarAction(point: NormPoint(x: 0.2, y: 0.15))), question: nil)
        return editor
    }

    @Test func lassoPicksWhatsInsideOnly() throws {
        let editor = populated()
        editor.select(lasso: lasso(0.05, 0.05, 0.3, 0.2))
        let selection = try #require(editor.selection)
        #expect(selection.strokeIndices == [0])
        #expect(selection.annotationIDs == [editor.annotations[0].id])
        #expect(selection.bounds.minX < 100.0 / 816 && selection.bounds.maxX > 200.0 / 816)
    }

    @Test func tapSelectsOneThingAndEmptyPaperOffersPaste() {
        let editor = populated()
        editor.select(at: NormPoint(x: 650.0 / 816, y: 925.0 / 1056))
        #expect(editor.selection?.strokeIndices == [1])
        editor.select(at: NormPoint(x: 0.5, y: 0.5))
        #expect(editor.selection == nil)
        PageClipboard.content = nil
        editor.select(at: NormPoint(x: 0.5, y: 0.5))
        #expect(editor.pasteAnchor == nil || UIPasteboard.general.hasImages, "nothing to paste")
    }

    @Test func movingAndScalingTransformsEverythingAndIsOneUndoStep() throws {
        let editor = populated()
        editor.select(lasso: lasso(0.05, 0.05, 0.3, 0.2))
        let before = try #require(editor.selection).bounds
        let starBefore = editor.annotations[0]
        endEvent()

        editor.beginSelectionTransform()
        editor.updateSelectionTransform(translation: NormPoint(x: 0.1, y: 0.2), scale: 1)
        editor.updateSelectionTransform(translation: NormPoint(x: 0.2, y: 0.3), scale: 2)   // from the base, not cumulative
        editor.endSelectionTransform()
        endEvent()

        let after = try #require(editor.selection).bounds
        #expect(abs(after.x - (before.x + 0.2)) < 0.01 && abs(after.y - (before.y + 0.3)) < 0.01)
        #expect(after.width > before.width * 1.8)
        let moved = editor.drawing.strokes[0].renderBounds
        #expect(moved.minX > 100 + 0.2 * 816 - 10, "ink moved")
        #expect(editor.drawing.strokes[1].renderBounds.minX < 700, "unselected ink stayed")
        guard case .star(let s) = editor.annotations[0].action else { Issue.record("star"); return }
        #expect(abs(s.point.x - (before.x + (0.2 - before.x) * 2 + 0.2)) < 0.001, "star scaled about the box's corner and moved")
        // Persisted.
        #expect(editor.store.annotations(for: editor.page.id, in: editor.notebookID).first?.action == editor.annotations[0].action)

        editor.undo()
        #expect(editor.annotations[0].action == starBefore.action)
        #expect(abs(editor.drawing.strokes[0].renderBounds.minX - 100) < 10)
    }

    @Test func copyPasteDuplicateDeleteAndUndo() throws {
        let editor = populated()
        editor.select(lasso: lasso(0.05, 0.05, 0.3, 0.2))
        editor.copySelection()
        editor.paste(at: NormPoint(x: 0.5, y: 0.5))
        endEvent()
        #expect(editor.drawing.strokes.count == 3)
        #expect(editor.annotations.count == 2)
        let pasted = try #require(editor.selection)
        #expect(abs(pasted.bounds.x - 0.5) < 0.01 && abs(pasted.bounds.y - 0.5) < 0.01, "pasted where asked")
        #expect(Set(editor.annotations.map(\.id)).count == 2, "pasted marks get new ids")

        editor.duplicateSelection()
        endEvent()
        #expect(editor.drawing.strokes.count == 4)

        editor.deleteSelection()
        endEvent()
        #expect(editor.drawing.strokes.count == 3)
        editor.undo()
        #expect(editor.drawing.strokes.count == 4)
    }

    @Test func imagesMoveAndCopyToo() throws {
        let editor = makeEditor()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }.pngData()!
        let placed = try editor.store.addImage(png, to: editor.page.id, in: editor.notebookID, center: NormPoint(x: 0.3, y: 0.3))
        editor.imageInsertedExternally(placed)
        editor.select(at: placed.frame.center)
        #expect(editor.selection?.imageIDs == [placed.id])
        editor.beginSelectionTransform()
        editor.updateSelectionTransform(translation: NormPoint(x: 0.2, y: 0), scale: 1)
        editor.endSelectionTransform()
        let frame = try #require(editor.store.notebook(id: editor.notebookID)?.pages[0].images.first?.frame)
        #expect(abs(frame.x - (placed.frame.x + 0.2)) < 1e-6, "saved")
        editor.copySelection()
        editor.paste(at: nil)
        #expect(editor.page.images.count == 2)
    }

    @Test func makeItMyInkTurnsInkysDrawingIntoStrokesAndKeepsText() throws {
        let editor = makeEditor()
        editor.addAnnotation(.draw(DrawAction(ink: .pen, color: .indigo, shapes: [
            .init(kind: .line, points: [NormPoint(x: 0.3, y: 0.3), NormPoint(x: 0.4, y: 0.3)], text: nil, size: .medium),
            .init(kind: .arrow, points: [NormPoint(x: 0.3, y: 0.35), NormPoint(x: 0.4, y: 0.35)], text: nil, size: .medium),
            .init(kind: .text, points: [NormPoint(x: 0.41, y: 0.29)], text: "H", size: .small),
        ], caption: nil)), question: nil)
        editor.select(lasso: lasso(0.2, 0.2, 0.4, 0.3))
        #expect(editor.selectedDrawingCount == 1)
        editor.convertSelectedDrawingsToInk()
        #expect(editor.drawing.strokes.count == 3, "line, shaft, head")
        guard case .draw(let rest) = try #require(editor.annotations.first).action else { Issue.record("text kept"); return }
        #expect(rest.shapes.map(\.kind) == [.text])
        #expect(editor.selection?.strokeIndices.count == 3)
    }

    @Test func askingInkyLassoesTheSelection() throws {
        let editor = populated()
        editor.select(lasso: lasso(0.05, 0.05, 0.3, 0.2))
        let bounds = try #require(editor.selection).bounds
        editor.lassoSelectionForInky()
        let region = try #require(editor.lassoRegion)
        #expect(region.minX <= bounds.minX && region.maxX >= bounds.maxX)
        #expect(!editor.isSelectMode && editor.selection == nil)
    }
}
