import PencilKit
import UIKit
import Vision

/// The Text tool (typed text boxes) and converting handwriting to text.
extension PageEditorModel {
    func textBox(at point: NormPoint) -> PageTextBox? {
        page.textBoxes.last { $0.frame.insetBy(dx: -0.01, dy: -0.01).contains(point) }
    }

    /// Text tool tap: edit the box under the point, or start a new one there. A tap while
    /// editing finishes the current box first.
    func textTap(at point: NormPoint) {
        if editingTextBoxID != nil {
            let tappedOther = textBox(at: point).map { $0.id != editingTextBoxID } ?? false
            endTextEditing()
            guard tappedOther else { return }
        }
        textEditBase = contentSnapshot
        if let box = textBox(at: point) {
            editingTextBoxID = box.id
            return
        }
        let width = min(0.45, 0.97 - point.x)
        var box = PageTextBox(frame: NormRect(x: point.x, y: max(0.01, point.y - 0.012), width: max(width, 0.15), height: 0.03), text: "")
        box.frame.height = PageRenderer.textBoxHeight(box, pageSize: page.size)
        setTextBoxes(page.textBoxes + [box], save: false)
        editingTextBoxID = box.id
    }

    /// Live edit (typing, size, style, color); saved when editing ends.
    func updateTextBox(_ box: PageTextBox) {
        guard let index = page.textBoxes.firstIndex(where: { $0.id == box.id }) else { return }
        var updated = box
        updated.frame.height = PageRenderer.textBoxHeight(box, pageSize: page.size)
        var boxes = page.textBoxes
        boxes[index] = updated
        setTextBoxes(boxes, save: false)
    }

    func deleteTextBox(_ id: UUID) {
        if editingTextBoxID == id { editingTextBoxID = nil }
        let before = textEditBase ?? contentSnapshot
        textEditBase = nil
        setTextBoxes(page.textBoxes.filter { $0.id != id }, save: true)
        registerContentUndo(restoring: before, actionName: "Delete Text")
    }

    /// Finishes typing: an empty box goes away; otherwise it's saved as one undo step.
    func endTextEditing() {
        guard let id = editingTextBoxID else { return }
        editingTextBoxID = nil
        let empty = page.textBoxes.first { $0.id == id }?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if empty { setTextBoxes(page.textBoxes.filter { $0.id != id }, save: false) }
        setTextBoxes(page.textBoxes, save: true)
        if let base = textEditBase, base.textBoxes != page.textBoxes {
            registerContentUndo(restoring: base, actionName: empty ? "Delete Text" : "Typing")
        }
        textEditBase = nil
    }

    // MARK: Handwriting → text

    /// Selected ink strokes, read with on-device text recognition, become a text box in their
    /// place (one undo step). Returns false when nothing legible was found.
    @discardableResult
    func convertSelectedInkToText() async -> Bool {
        guard let selection, !selection.strokeIndices.isEmpty else { return false }
        let strokes = selection.strokeIndices.compactMap { drawing.strokes.indices.contains($0) ? drawing.strokes[$0] : nil }
        let inkBounds = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }.insetBy(dx: -12, dy: -12)
        guard let lines = await Self.recognizeHandwriting(PKDrawing(strokes: strokes), in: inkBounds), !lines.isEmpty else { return false }

        let before = contentSnapshot
        let text = lines.map(\.text).joined(separator: "\n")
        // Size the text like the handwriting it replaces.
        let lineHeight = lines.map(\.height).sorted()[lines.count / 2]
        var box = PageTextBox(frame: NormRect(inkBounds.insetBy(dx: 12, dy: 12), in: page.size), text: text,
                              fontSize: min(max(Double(lineHeight) * 0.7, 12), 48))
        box.frame.width = max(box.frame.width, 0.12)
        box.frame.height = PageRenderer.textBoxHeight(box, pageSize: page.size)
        let removed = Set(selection.strokeIndices)
        applyDrawing(PKDrawing(strokes: drawing.strokes.enumerated().filter { !removed.contains($0.offset) }.map(\.element)))
        setTextBoxes(page.textBoxes + [box], save: true)
        self.selection = PageSelection(textBoxIDs: [box.id], bounds: box.frame)
        registerContentUndo(restoring: before, actionName: "Convert to Text")
        return true
    }

    struct HandwritingLine: Sendable { var text: String; var height: CGFloat }

    /// Vision's handwriting recognition on the strokes rendered black on white.
    static func recognizeHandwriting(_ drawing: PKDrawing, in rect: CGRect) async -> [HandwritingLine]? {
        let scale: CGFloat = 3
        var inkImage = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            inkImage = drawing.image(from: rect, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: rect.size))
            inkImage.draw(in: CGRect(origin: .zero, size: rect.size))
        }
        guard let cg = image.cgImage else { return nil }
        let pointHeight = rect.height
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: cg).perform([request])
                let lines = (request.results ?? [])
                    .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                    .compactMap { observation -> HandwritingLine? in
                        guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
                        return HandwritingLine(text: text, height: observation.boundingBox.height * pointHeight)
                    }
                continuation.resume(returning: lines)
            }
        }
    }
}
