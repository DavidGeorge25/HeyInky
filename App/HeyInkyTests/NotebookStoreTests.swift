import PencilKit
import Testing
import UIKit
@testable import HeyInky

@MainActor
@Suite("Notebook store")
struct NotebookStoreTests {
    @Test func createsPersistsAndReloadsNotebooks() {
        let root = Fixtures.tempDirectory()
        let store = NotebookStore(rootURL: root)
        let notebook = store.createNotebook(title: "Organic Chem", paper: .grid)
        #expect(notebook.pages.count == 1)
        #expect(notebook.pages[0].background == .paper(.grid))

        let reloaded = NotebookStore(rootURL: root)
        #expect(reloaded.notebooks.map(\.title) == ["Organic Chem"])
        reloaded.rename(notebook.id, to: "Orgo")
        #expect(NotebookStore(rootURL: root).notebook(id: notebook.id)?.title == "Orgo")
    }

    @Test func addsAndDeletesPages() {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "N")
        let added = store.addPage(to: notebook.id, at: 0, background: .paper(.dotted))
        #expect(store.notebook(id: notebook.id)?.pages.first?.id == added?.id)
        #expect(store.notebook(id: notebook.id)?.pages.count == 2)

        store.deletePage(added!.id, from: notebook.id)
        #expect(store.notebook(id: notebook.id)?.pages.count == 1)
        // Deleting the last page leaves a fresh blank one.
        store.deletePage(store.notebook(id: notebook.id)!.pages[0].id, from: notebook.id)
        #expect(store.notebook(id: notebook.id)?.pages.count == 1)
    }

    @Test func savesInkAndInkyLayerPerPage() {
        let root = Fixtures.tempDirectory()
        let store = NotebookStore(rootURL: root)
        let notebook = store.createNotebook(title: "N")
        let pageID = notebook.pages[0].id

        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [
            PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 200, y: 200), timeOffset: 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
        ], creationDate: .now))
        store.saveDrawing(PKDrawing(strokes: [stroke]), for: pageID, in: notebook.id)
        let annotation = InkyAnnotation(action: .say(SayAction(text: "x")))
        store.saveAnnotations([annotation], for: pageID, in: notebook.id)

        let reloaded = NotebookStore(rootURL: root)
        #expect(reloaded.drawing(for: pageID, in: notebook.id).strokes.count == 1)
        let loaded = reloaded.annotations(for: pageID, in: notebook.id)
        #expect(loaded.map(\.id) == [annotation.id])
        #expect(loaded.first?.action == annotation.action)
    }

    @Test func inkyLayerVisibilityPersistsPerNotebook() throws {
        let root = Fixtures.tempDirectory()
        let store = NotebookStore(rootURL: root)
        let notebook = store.createNotebook(title: "N")
        let page = notebook.pages[0]
        let editor = PageEditorModel(notebookID: notebook.id, page: page, store: store)
        #expect(editor.showsInkyLayer)
        editor.showsInkyLayer = false

        let reloaded = NotebookStore(rootURL: root)
        #expect(!PageEditorModel(notebookID: notebook.id, page: page, store: reloaded).showsInkyLayer, "survives relaunch")
        // Older notebook.json files without the key still decode (layer shown).
        let url = reloaded.directory(for: notebook.id).appendingPathComponent("notebook.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["inkyLayerHidden"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(NotebookStore(rootURL: root).notebook(id: notebook.id)?.inkyLayerHidden == nil)
    }

    @Test func editorAutosavesInkAfterDelay() async throws {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "N")
        let editor = PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [
            PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: 1),
        ], creationDate: .now))
        editor.drawingDidChange(PKDrawing(strokes: [stroke]))
        #expect(store.drawing(for: notebook.pages[0].id, in: notebook.id).strokes.isEmpty, "debounced")
        try await Task.sleep(for: PageEditorModel.autosaveDelay + .milliseconds(400))
        #expect(store.drawing(for: notebook.pages[0].id, in: notebook.id).strokes.count == 1)
    }

    @Test func importsPDFAsPagesAndExtractsText() throws {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let url = try SampleContent.writeSamplePDF()
        let (notebook, firstIndex) = try store.importPDF(from: url, title: "Slides")
        #expect(firstIndex == 0)
        #expect(notebook.pages.count == 1)
        let page = notebook.pages[0]
        #expect(page.size == SampleContent.pageSize)
        guard case .pdf(let asset, 0) = page.background else { Issue.record("expected pdf page"); return }
        #expect(FileManager.default.fileExists(atPath: store.assetURL(asset, in: notebook.id).path))

        let lines = PageRenderer.pdfTextLines(page: page, notebookID: notebook.id, store: store)
        let title = try #require(lines.first { $0.text.contains("Chemical Equilibrium") })
        #expect(title.box.intersectionOverUnion(SampleContent.titleRegion) > 0.5)

        // Appending into an existing notebook.
        let (again, second) = try store.importPDF(from: url, into: notebook.id)
        #expect(second == 1)
        #expect(again.pages.count == 2)
    }

    @Test func insertsImagesCenteredAndInBounds() throws {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "N")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }.pngData()!
        let placed = try store.addImage(png, to: notebook.pages[0].id, in: notebook.id)
        #expect(abs(placed.frame.center.x - 0.5) < 0.001)
        #expect(placed.frame.width <= 0.6 + 1e-9)
        #expect(store.image(placed.asset, in: notebook.id) != nil)
        #expect(store.notebook(id: notebook.id)?.pages[0].images == [placed])
    }

    @Test func rendersPageWithBackgroundAndImage() throws {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "N", paper: .blank)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }.pngData()!
        let placed = try store.addImage(png, to: notebook.pages[0].id, in: notebook.id)
        let page = store.notebook(id: notebook.id)!.pages[0]
        let image = PageRenderer.image(page: page, notebookID: notebook.id, store: store, drawing: nil, pixelWidth: 408)
        let center = placed.frame.center.cgPoint(in: image.size)
        let p = image.pixel(at: center)
        #expect(p.r > 0.9 && p.g < 0.2, "image drawn")
        let corner = image.pixel(at: CGPoint(x: 5, y: 5))
        #expect(corner.r > 0.95 && corner.g > 0.95, "white paper")
    }
}
