import Foundation
import Observation
import PencilKit
import UIKit

/// State for the page on screen: ink, the Inky layer, lasso and selection. Autosaves.
@MainActor
@Observable
final class PageEditorModel {
    let notebookID: UUID
    private(set) var page: Page
    let store: NotebookStore

    private(set) var drawing: PKDrawing
    private(set) var annotations: [InkyAnnotation]

    var showsInkyLayer = true
    var selectedAnnotationID: UUID?
    var selectedImageID: UUID?

    /// True while Inky is summoned: touches on the page draw a lasso instead of ink.
    var isInkyMode = false
    private(set) var lassoPath: [NormPoint] = []
    private(set) var lassoRegion: NormRect?

    /// Set by the canvas controller; used for undo/redo and snapshots.
    @ObservationIgnored weak var canvasController: PageCanvasController?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private(set) var hasUnsavedInk = false
    static let autosaveDelay: Duration = .milliseconds(800)

    init(notebookID: UUID, page: Page, store: NotebookStore) {
        self.notebookID = notebookID
        self.page = page
        self.store = store
        self.drawing = store.drawing(for: page.id, in: notebookID)
        self.annotations = store.annotations(for: page.id, in: notebookID)
    }

    // MARK: Ink

    func drawingDidChange(_ drawing: PKDrawing) {
        self.drawing = drawing
        hasUnsavedInk = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: PageEditorModel.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard hasUnsavedInk else { return }
        store.saveDrawing(drawing, for: page.id, in: notebookID)
        hasUnsavedInk = false
    }

    func undo() { canvasController?.undo() }
    func redo() { canvasController?.redo() }

    // MARK: Inky layer

    var visibleAnnotations: [InkyAnnotation] {
        showsInkyLayer ? annotations.filter { !$0.isHidden } : []
    }

    func addAnnotation(_ action: InkyAction, question: String?) {
        guard action.isPageAnnotation else { return }
        annotations.append(InkyAnnotation(action: action, question: question))
        saveAnnotations()
    }

    func updateAnnotation(_ annotation: InkyAnnotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
        saveAnnotations()
    }

    func moveAnnotation(_ id: UUID, by delta: NormPoint) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].offset = annotations[index].offset.offsetBy(dx: delta.x, dy: delta.y)
        saveAnnotations()
    }

    func setHidden(_ id: UUID, _ hidden: Bool) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].isHidden = hidden
        if hidden, selectedAnnotationID == id { selectedAnnotationID = nil }
        saveAnnotations()
    }

    func deleteAnnotation(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        if selectedAnnotationID == id { selectedAnnotationID = nil }
        saveAnnotations()
    }

    func clearAnnotations() {
        annotations.removeAll()
        selectedAnnotationID = nil
        saveAnnotations()
    }

    private func saveAnnotations() {
        store.saveAnnotations(annotations, for: page.id, in: notebookID)
    }

    /// Whether a touch at this normalized point should go to the Inky layer instead of the ink.
    func overlayWantsTouch(at point: NormPoint) -> Bool {
        if selectedAnnotationID != nil || selectedImageID != nil { return true }
        return visibleAnnotations.contains { annotation in
            InkyAnnotationGeometry.hitRect(for: annotation, pageSize: page.size).contains(point)
        }
    }

    // MARK: Images

    func updateImage(_ image: PlacedImage) {
        guard let index = page.images.firstIndex(where: { $0.id == image.id }) else { return }
        page.images[index] = image
        store.updatePage(page, in: notebookID)
    }

    func deleteImage(_ id: UUID) {
        page.images.removeAll { $0.id == id }
        if selectedImageID == id { selectedImageID = nil }
        store.updatePage(page, in: notebookID)
    }

    func imageInsertedExternally(_ placed: PlacedImage) {
        if let fresh = store.notebook(id: notebookID)?.pages.first(where: { $0.id == page.id }) {
            page = fresh
        }
        selectedImageID = placed.id
    }

    func image(at point: NormPoint) -> PlacedImage? {
        page.images.last { $0.frame.contains(point) }
    }

    // MARK: Lasso

    func setLasso(path: [NormPoint]) {
        guard path.count > 2 else { return }
        lassoPath = path
        let xs = path.map(\.x), ys = path.map(\.y)
        lassoRegion = NormRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).clamped
    }

    func clearLasso() {
        lassoPath = []
        lassoRegion = nil
    }

    // MARK: Snapshot for Inky

    /// Page rendered for the model (no grid; `InkyLocalization` adds it) plus text lines.
    func snapshotForInky() async -> (image: UIImage, text: [RecognizedTextLine]) {
        flush()
        let width = InkyLocalization.tuning.fullPageLongEdge * max(1, page.width / page.height) * 1.25
        let full = PageRenderer.image(page: page, notebookID: notebookID, store: store, drawing: drawing, pixelWidth: width)
        var lines = PageRenderer.pdfTextLines(page: page, notebookID: notebookID, store: store)
        // OCR everything that isn't already PDF text (ink, images, scanned PDFs).
        let ocrLayers: PageRenderer.Layers = lines.isEmpty ? .all : [.images, .ink]
        let ocrSource = lines.isEmpty ? full : PageRenderer.image(page: page, notebookID: notebookID, store: store, drawing: drawing, pixelWidth: width, layers: ocrLayers)
        if let cg = ocrSource.cgImage {
            lines += await InkyLocalization.recognizeText(in: cg)
        }
        return (full, lines.sorted { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) })
    }
}
