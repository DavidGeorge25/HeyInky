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
    /// The Select tool is active: touches lasso/tap to select instead of inking.
    var isSelectMode = false {
        didSet { if !isSelectMode { selection = nil; pasteAnchor = nil } }
    }
    /// What the Select tool has picked (see `PageEditorModel+Selection`).
    var selection: PageSelection?
    /// Where a tap on empty paper offered "Paste".
    var pasteAnchor: NormPoint?
    /// The Text tool is active: a tap places or edits a text box.
    var isTextMode = false {
        didSet { if !isTextMode { endTextEditing() } }
    }
    /// The text box being typed into (drawn live by the editor overlay, not the background).
    var editingTextBoxID: UUID?
    @ObservationIgnored var textEditBase: PageContentSnapshot?
    @ObservationIgnored var transformBase: (PageContentSnapshot, PageSelection)?
    /// Set by the notebook: summon Inky about the current selection.
    @ObservationIgnored var onAskInkyAboutSelection: (() -> Void)?
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

    /// Draw-and-hold shape correction (More menu → Shape Correction). On by default.
    static var shapeCorrectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "HeyInkyShapeCorrection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "HeyInkyShapeCorrection") }
    }

    func drawingDidChange(_ drawing: PKDrawing) {
        let previousCount = self.drawing.strokes.count
        self.drawing = drawing
        if drawing.strokes.count == previousCount + 1, let stroke = drawing.strokes.last {
            if ShapeRecognizer.endsWithHold(stroke) {
                // The hold is visible in the stroke's own timing (a Pencil reports a resting nib).
                Task { @MainActor [weak self] in self?.correctLastShape() }
            } else if let lift = pendingLift, drawing.strokes.count == strokesAtPenDown + 1 {
                pendingLift = nil
                penLifted(at: lift)
            }
        }
        hasUnsavedInk = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: PageEditorModel.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Replaces the ink (Select tool edits, undo of those). Updates the canvas without going
    /// through PencilKit's own undo.
    func applyDrawing(_ newDrawing: PKDrawing) {
        drawing = newDrawing
        canvasController?.showDrawing(newDrawing)
        drawingDidChange(newDrawing)
    }

    func setTextBoxes(_ boxes: [PageTextBox], save: Bool) {
        page.textBoxes = boxes
        if save { store.updatePage(page, in: notebookID) }
    }

    func setImages(_ images: [PlacedImage], save: Bool) {
        page.images = images
        if save { store.updatePage(page, in: notebookID) }
    }

    func setAnnotations(_ list: [InkyAnnotation], save: Bool) {
        annotations = list
        if save { saveAnnotations() }
    }

    @ObservationIgnored private var strokesAtPenDown = 0
    @ObservationIgnored private var pendingLift: Date?

    func penDown(strokes: Int) {
        strokesAtPenDown = strokes
        pendingLift = nil
    }

    /// The pen left the page. The new stroke usually arrives just after; check then.
    func penUp(at date: Date) {
        if drawing.strokes.count == strokesAtPenDown + 1 {
            penLifted(at: date)
        } else {
            pendingLift = date
        }
    }

    /// The pen was lifted at `date`: if it rested still for a moment first (finger and simulator
    /// touches report no movement while held), snap the stroke just drawn.
    func penLifted(at date: Date) {
        guard let stroke = drawing.strokes.last, let last = stroke.path.last else { return }
        let lastMovement = stroke.path.creationDate.addingTimeInterval(last.timeOffset)
        let age = date.timeIntervalSince(stroke.path.creationDate)
        // Only the stroke that just ended.
        guard age >= 0, age < 30, date.timeIntervalSince(lastMovement) >= ShapeRecognizer.holdDuration else { return }
        Task { @MainActor [weak self] in self?.correctLastShape() }
    }

    /// Replaces the newest stroke with the clean shape it is (if it's one). One step: PencilKit's
    /// undo of the stroke also removes the shape.
    func correctLastShape() {
        guard Self.shapeCorrectionEnabled, let stroke = drawing.strokes.last, !ShapeRecognizer.isClean(stroke),
              let clean = ShapeRecognizer.corrected(stroke) else { return }
        var strokes = drawing.strokes
        strokes[strokes.count - 1] = clean
        applyDrawing(PKDrawing(strokes: strokes))
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

    /// - Parameter exact: geometry was computed by the app (`StructureAnnotator`); don't re-aim
    ///   bonds or move text.
    func addAnnotation(_ action: InkyAction, question: String?, exact: Bool = false) {
        guard action.isPageAnnotation else { return }
        var action = action
        if !exact, case .draw(var drawing) = action {
            // Clean angles for atoms added to the student's structure, then keep the writing readable.
            let skeleton = InkSkeleton.paths(in: self.drawing, pageSize: page.size, handwriting: (lastRecognizedText ?? []).map(\.box))
            drawing = BondLayout.refine(drawing, skeleton: skeleton, pageSize: page.size)
            action = .draw(InkyLayout.placingDrawText(drawing, among: visibleAnnotations, pageSize: page.size))
        }
        var annotation = InkyAnnotation(action: action, question: question)
        annotation.labelPlacement = InkyLayout.bestPlacement(for: action, among: visibleAnnotations, content: layoutContent, pageSize: page.size)
        annotations.append(annotation)
        saveAnnotations()
    }

    /// Everything a new figure shouldn't cover: ink, text, images and Inky's visible marks.
    var figureObstacles: [NormRect] {
        layoutContent + page.images.map(\.frame) + visibleAnnotations.map { InkyAnnotationGeometry.bounds(for: $0, pageSize: page.size) }
    }

    /// What's on the page that Inky's text shouldn't cover: ink, plus the text lines Inky last read
    /// (PDF text layer / OCR of ink and images, cached by `snapshotForInky`).
    var layoutContent: [NormRect] {
        let size = page.size
        let ink = drawing.strokes.map { NormRect($0.renderBounds, in: size) }
        let text = (lastRecognizedText ?? PageRenderer.pdfTextLines(page: page, notebookID: notebookID, store: store)).map(\.box)
        return ink + text
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
    /// Text lines from the last `snapshotForInky` (nil = not read yet).
    @ObservationIgnored private(set) var lastRecognizedText: [RecognizedTextLine]?

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
        lines.sort { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) }
        lastRecognizedText = lines
        return (full, lines)
    }
}
