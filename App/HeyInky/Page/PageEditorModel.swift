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

    /// Whole-layer visibility, persisted per notebook.
    var showsInkyLayer = true {
        didSet { if showsInkyLayer != oldValue { store.setInkyLayerHidden(!showsInkyLayer, in: notebookID) } }
    }
    /// Plays Inky hopping over and drawing each new annotation (InkyCharacter module).
    let choreographer = InkyChoreographer()
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
        self.showsInkyLayer = !(store.notebook(id: notebookID)?.inkyLayerHidden ?? false)
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

    /// This page's undo history, shared by ink (the canvas returns it as its `undoManager`, so
    /// PencilKit registers strokes here) and Inky annotation changes. Per page, so undo never
    /// reaches into another page.
    @ObservationIgnored let undoManager = UndoManager()

    func undo() { undoManager.undo() }
    func redo() { undoManager.redo() }

    // MARK: Inky layer

    var visibleAnnotations: [InkyAnnotation] {
        showsInkyLayer ? annotations.filter { !$0.isHidden } : []
    }

    func addAnnotation(_ action: InkyAction, question: String?) {
        guard action.isPageAnnotation else { return }
        var annotation = InkyAnnotation(action: action, question: question)
        if case .label(let label) = action { annotation.labelPlacement = freeLabelPlacement(for: label) }
        annotations.append(annotation)
        saveAnnotations()
    }

    /// The first label placement whose text box doesn't overlap another visible label's (nil = default).
    private func freeLabelPlacement(for label: LabelAction) -> Int? {
        let taken = visibleAnnotations.compactMap { other -> NormRect? in
            guard case .label(let l) = other.action else { return nil }
            return InkyAnnotationGeometry.labelTextRect(l, pageSize: page.size, placement: other.labelPlacement ?? 0)
                .offsetBy(dx: other.offset.x, dy: other.offset.y)
        }
        let margin = 4 / page.width
        for placement in InkyAnnotationGeometry.labelPlacements {
            let rect = InkyAnnotationGeometry.labelTextRect(label, pageSize: page.size, placement: placement).insetBy(dx: -margin, dy: -margin)
            if !taken.contains(where: { $0.intersects(rect) }) { return placement == 0 ? nil : placement }
        }
        return nil
    }

    /// Cards call this for every slider/expression edit, so it isn't undoable by default;
    /// user edits from the selection toolbar pass `undoable: true`.
    func updateAnnotation(_ annotation: InkyAnnotation, undoable: Bool = false) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        let before = annotations
        annotations[index] = annotation
        saveAnnotations()
        if undoable { registerAnnotationUndo(restoring: before, actionName: "Edit") }
    }

    func moveAnnotation(_ id: UUID, by delta: NormPoint) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let before = annotations
        annotations[index].offset = annotations[index].offset.offsetBy(dx: delta.x, dy: delta.y)
        saveAnnotations()
        registerAnnotationUndo(restoring: before, actionName: "Move")
    }

    func setHidden(_ id: UUID, _ hidden: Bool) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let before = annotations
        annotations[index].isHidden = hidden
        if hidden, selectedAnnotationID == id { selectedAnnotationID = nil }
        saveAnnotations()
        registerAnnotationUndo(restoring: before, actionName: hidden ? "Hide" : "Show")
    }

    /// `undoable: false` when the deletion is part of a larger undoable change (an Inky turn, flatten).
    func deleteAnnotation(_ id: UUID, undoable: Bool = true) {
        let before = annotations
        annotations.removeAll { $0.id == id }
        if selectedAnnotationID == id { selectedAnnotationID = nil }
        saveAnnotations()
        if undoable { registerAnnotationUndo(restoring: before, actionName: "Delete") }
    }

    func clearAnnotations() {
        let before = annotations
        annotations.removeAll()
        selectedAnnotationID = nil
        saveAnnotations()
        registerAnnotationUndo(restoring: before, actionName: "Clear Inky Layer")
    }

    /// Makes the change from `before` to the current annotations one undo step (redo re-applies it).
    func registerAnnotationUndo(restoring before: [InkyAnnotation], actionName: String) {
        guard before != annotations else { return }
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                let current = editor.annotations
                editor.restoreAnnotations(before)
                editor.registerAnnotationUndo(restoring: current, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func restoreAnnotations(_ list: [InkyAnnotation]) {
        annotations = list
        if let id = selectedAnnotationID, !list.contains(where: { $0.id == id }) { selectedAnnotationID = nil }
        saveAnnotations()
    }

    /// Replaces an annotation (a flattened card) with a placed image at the same frame.
    func replaceAnnotationWithImage(_ id: UUID, image: UIImage) {
        guard let annotation = annotations.first(where: { $0.id == id }), let data = image.pngData() else { return }
        let frame = InkyAnnotationGeometry.bounds(for: annotation, pageSize: page.size)
        guard var placed = try? store.addImage(data, to: page.id, in: notebookID, center: frame.center) else { return }
        placed.frame = frame
        imageInsertedExternally(placed)
        updateImage(placed)
        selectedImageID = nil
        deleteAnnotation(id, undoable: false)
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
