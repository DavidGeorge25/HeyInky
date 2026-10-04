import PencilKit
import UIKit

/// The Select tool: lasso or tap to pick ink, images and Inky marks; move / scale them live;
/// copy, cut, paste, duplicate, delete; or ask Inky about just the selection. Every change is
/// one undo step (a whole-page snapshot).
extension PageEditorModel {
    // MARK: Picking

    /// Selects what a lasso loop (normalized page points) encloses: strokes with most of their
    /// length inside, images and Inky marks whose center is inside.
    func select(lasso path: [NormPoint]) {
        pasteAnchor = nil
        let size = page.size
        let polygon = path.map { $0.cgPoint(in: size) }
        guard polygon.count > 2 else { selection = nil; return }
        var result = PageSelection()
        for (i, stroke) in drawing.strokes.enumerated() {
            let points = SelectionGeometry.samplePoints(stroke)
            let inside = points.filter { SelectionGeometry.contains(polygon, $0) }.count
            if Double(inside) >= Double(points.count) * 0.5 { result.strokeIndices.append(i) }
        }
        for image in page.images where SelectionGeometry.contains(polygon, image.frame.center.cgPoint(in: size)) {
            result.imageIDs.insert(image.id)
        }
        for annotation in visibleAnnotations {
            let center = InkyAnnotationGeometry.bounds(for: annotation, pageSize: size).center
            if SelectionGeometry.contains(polygon, center.cgPoint(in: size)) { result.annotationIDs.insert(annotation.id) }
        }
        setSelection(result)
    }

    /// Tap: the topmost thing under the point (Inky mark, then ink, then image). Tapping empty
    /// paper clears the selection, or offers Paste there when something is on the clipboard.
    func select(at point: NormPoint) {
        let size = page.size
        let p = point.cgPoint(in: size)
        var result = PageSelection()
        if let annotation = visibleAnnotations.last(where: { InkyAnnotationGeometry.hitRect(for: $0, pageSize: size).contains(point) }) {
            result.annotationIDs = [annotation.id]
        } else if let index = drawing.strokes.indices.last(where: { i in
            let stroke = drawing.strokes[i]
            guard stroke.renderBounds.insetBy(dx: -14, dy: -14).contains(p) else { return false }
            return SelectionGeometry.samplePoints(stroke, spacing: 3).contains { hypot($0.x - p.x, $0.y - p.y) < 14 }
        }) {
            result.strokeIndices = [index]
        } else if let image = image(at: point) {
            result.imageIDs = [image.id]
        }
        if result.isEmpty {
            let hadSelection = selection != nil
            selection = nil
            pasteAnchor = (!hadSelection && PageClipboard.hasContent) ? point : nil
        } else {
            pasteAnchor = nil
            setSelection(result)
        }
    }

    func clearSelection() {
        selection = nil
        pasteAnchor = nil
    }

    private func setSelection(_ value: PageSelection) {
        var value = value
        guard !value.isEmpty else { selection = nil; return }
        value.bounds = bounds(of: value)
        selection = value
        selectedAnnotationID = nil
        selectedImageID = nil
    }

    func bounds(of selection: PageSelection) -> NormRect {
        let size = page.size
        var rects: [NormRect] = selection.strokeIndices.compactMap { i in
            drawing.strokes.indices.contains(i) ? NormRect(drawing.strokes[i].renderBounds, in: size) : nil
        }
        rects += page.images.filter { selection.imageIDs.contains($0.id) }.map(\.frame)
        rects += annotations.filter { selection.annotationIDs.contains($0.id) }.map { InkyAnnotationGeometry.bounds(for: $0, pageSize: size) }
        guard var union = rects.first else { return .zero }
        for r in rects.dropFirst() { union = InkyAnnotationGeometry.union(union, r) }
        return union
    }

    // MARK: Move / scale (live)

    /// Starts a drag or resize; `updateSelectionTransform` then works from this snapshot so the
    /// result doesn't drift, and `endSelectionTransform` makes it one undo step.
    func beginSelectionTransform() {
        guard let selection, transformBase == nil else { return }
        transformBase = (contentSnapshot, selection)
    }

    /// Moves the selection by `translation` and scales it by `scale` about its top-left corner.
    func updateSelectionTransform(translation: NormPoint, scale: CGFloat) {
        guard let (base, baseSelection) = transformBase else { return }
        let size = page.size
        let s = max(0.1, scale)
        let anchorNorm = CGPoint(x: baseSelection.bounds.x, y: baseSelection.bounds.y)
        let deltaNorm = CGPoint(x: translation.x, y: translation.y)

        // Ink, in page points.
        let anchor = CGPoint(x: anchorNorm.x * size.width, y: anchorNorm.y * size.height)
        let delta = CGPoint(x: deltaNorm.x * size.width, y: deltaNorm.y * size.height)
        let t = CGAffineTransform(translationX: anchor.x + delta.x, y: anchor.y + delta.y)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -anchor.x, y: -anchor.y)
        var strokes = base.drawing.strokes
        for i in baseSelection.strokeIndices where strokes.indices.contains(i) {
            strokes[i].transform = strokes[i].transform.concatenating(t)
        }
        applyDrawing(PKDrawing(strokes: strokes))

        var images = base.images
        for i in images.indices where baseSelection.imageIDs.contains(images[i].id) {
            images[i].frame = SelectionGeometry.transform(images[i].frame, anchor: anchorNorm, scale: s, delta: deltaNorm)
        }
        setImages(images, save: false)

        setAnnotations(base.annotations.map { annotation in
            guard baseSelection.annotationIDs.contains(annotation.id) else { return annotation }
            var moved = annotation.bakingOffset
            moved.action = moved.action.transformed(anchor: anchorNorm, scale: s, delta: deltaNorm)
            return moved
        }, save: false)

        var moved = baseSelection
        moved.bounds = bounds(of: baseSelection)
        selection = moved
    }

    func endSelectionTransform() {
        guard let (base, _) = transformBase else { return }
        transformBase = nil
        setImages(page.images, save: true)
        setAnnotations(annotations, save: true)
        registerContentUndo(restoring: base, actionName: "Move")
    }

    // MARK: Edit

    func deleteSelection() {
        guard let selection else { return }
        let before = contentSnapshot
        removeContent(of: selection)
        self.selection = nil
        registerContentUndo(restoring: before, actionName: "Delete")
    }

    func copySelection() {
        guard let selection else { return }
        let size = page.size
        PageClipboard.content = PageClipboard.Content(
            strokes: selection.strokeIndices.compactMap { drawing.strokes.indices.contains($0) ? drawing.strokes[$0] : nil },
            images: page.images.filter { selection.imageIDs.contains($0.id) }.compactMap { image in
                FileManager.default.contents(atPath: store.assetURL(image.asset, in: notebookID).path).map { ($0, image.frame) }
            },
            annotations: annotations.filter { selection.annotationIDs.contains($0.id) }.map(\.bakingOffset),
            bounds: selection.bounds,
            sourcePageSize: size
        )
    }

    func cutSelection() {
        copySelection()
        guard let selection else { return }
        let before = contentSnapshot
        removeContent(of: selection)
        self.selection = nil
        registerContentUndo(restoring: before, actionName: "Cut")
    }

    func duplicateSelection() {
        let saved = PageClipboard.content
        copySelection()
        paste(at: nil)
        PageClipboard.content = saved
    }

    /// Pastes the clipboard with its top-left at `point` (or slightly offset from where it was
    /// copied). Falls back to an image on the system pasteboard. The pasted items become the selection.
    func paste(at point: NormPoint?) {
        pasteAnchor = nil
        let before = contentSnapshot
        let size = page.size
        var pasted = PageSelection()

        if let content = PageClipboard.content {
            let target = point.map { CGPoint(x: $0.x, y: $0.y) }
                ?? CGPoint(x: content.bounds.x + 0.03, y: content.bounds.y + 0.03)
            let deltaNorm = CGPoint(x: target.x - content.bounds.x, y: target.y - content.bounds.y)
            let shift = CGAffineTransform(translationX: deltaNorm.x * size.width, y: deltaNorm.y * size.height)

            var strokes = drawing.strokes
            for var stroke in content.strokes {
                stroke.transform = stroke.transform.concatenating(shift)
                pasted.strokeIndices.append(strokes.count)
                strokes.append(stroke)
            }
            applyDrawing(PKDrawing(strokes: strokes))

            for image in content.images {
                guard var placed = try? store.addImage(image.data, to: page.id, in: notebookID) else { continue }
                placed.frame = SelectionGeometry.transform(image.frame, anchor: .zero, scale: 1, delta: deltaNorm)
                imageInsertedExternally(placed)
                updateImage(placed)
                pasted.imageIDs.insert(placed.id)
            }
            for var annotation in content.annotations {
                annotation.id = UUID()
                annotation.action = annotation.action.transformed(anchor: .zero, scale: 1, delta: deltaNorm)
                setAnnotations(annotations + [annotation], save: false)
                pasted.annotationIDs.insert(annotation.id)
            }
            setAnnotations(annotations, save: true)
        } else if let image = UIPasteboard.general.image, let data = image.pngData() {
            let center = point.map { NormPoint(x: $0.x + 0.15, y: $0.y + 0.1) } ?? NormPoint(x: 0.5, y: 0.4)
            if let placed = try? store.addImage(data, to: page.id, in: notebookID, center: center) {
                imageInsertedExternally(placed)
                pasted.imageIDs.insert(placed.id)
            }
        }
        selectedImageID = nil
        setSelection(pasted)
        registerContentUndo(restoring: before, actionName: "Paste")
    }

    /// Selected Inky drawings with strokes in them (what "Make it my ink" converts).
    var selectedDrawingCount: Int {
        guard let selection else { return 0 }
        return annotations.filter { annotation in
            guard selection.annotationIDs.contains(annotation.id), case .draw(let a) = annotation.action else { return false }
            return a.shapes.contains { $0.kind != .text }
        }.count
    }

    /// Turns Inky's selected drawings into the student's own ink (erasable, lassoable like any
    /// stroke). Handwritten text has no stroke form, so it stays on the Inky layer.
    func convertSelectedDrawingsToInk() {
        guard let selection else { return }
        let before = contentSnapshot
        let size = page.size
        var strokes = drawing.strokes
        var kept: [InkyAnnotation] = []
        var newSelection = selection
        newSelection.annotationIDs = []
        for annotation in annotations {
            guard selection.annotationIDs.contains(annotation.id), case .draw(let a) = annotation.bakingOffset.action else {
                kept.append(annotation)
                continue
            }
            let layout = DrawInk.layout(a, pageSize: size, seed: CircleMark.seed(for: annotation.id))
            for stroke in DrawInk.drawing(layout, action: a).strokes {
                newSelection.strokeIndices.append(strokes.count)
                strokes.append(stroke)
            }
            let texts = a.shapes.filter { $0.kind == .text }
            if !texts.isEmpty {
                var textOnly = annotation.bakingOffset
                var action = a
                action.shapes = texts
                textOnly.action = .draw(action)
                kept.append(textOnly)
                newSelection.annotationIDs.insert(textOnly.id)
            }
        }
        applyDrawing(PKDrawing(strokes: strokes))
        setAnnotations(kept, save: true)
        setSelection(newSelection)
        registerContentUndo(restoring: before, actionName: "Make Ink")
    }

    /// Points Inky at the selection: its bounds become Inky's lasso region.
    func lassoSelectionForInky() {
        guard let selection else { return }
        let pad = 0.01
        let r = selection.bounds.insetBy(dx: -pad, dy: -pad).clamped
        setLasso(path: [
            NormPoint(x: r.minX, y: r.minY), NormPoint(x: r.maxX, y: r.minY),
            NormPoint(x: r.maxX, y: r.maxY), NormPoint(x: r.minX, y: r.maxY),
        ])
        isSelectMode = false
    }

    // MARK: Snapshots and undo

    var contentSnapshot: PageContentSnapshot {
        PageContentSnapshot(drawing: drawing, images: page.images, annotations: annotations)
    }

    func registerContentUndo(restoring before: PageContentSnapshot, actionName: String) {
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                let current = editor.contentSnapshot
                editor.restoreContent(before)
                editor.registerContentUndo(restoring: current, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func restoreContent(_ snapshot: PageContentSnapshot) {
        selection = nil
        applyDrawing(snapshot.drawing)
        setImages(snapshot.images, save: true)
        setAnnotations(snapshot.annotations, save: true)
    }

    private func removeContent(of selection: PageSelection) {
        let removed = Set(selection.strokeIndices)
        applyDrawing(PKDrawing(strokes: drawing.strokes.enumerated().filter { !removed.contains($0.offset) }.map(\.element)))
        setImages(page.images.filter { !selection.imageIDs.contains($0.id) }, save: true)
        setAnnotations(annotations.filter { !selection.annotationIDs.contains($0.id) }, save: true)
    }
}
