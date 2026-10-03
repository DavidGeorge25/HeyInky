import SwiftUI
import Testing
@testable import HeyInky

@MainActor
@Suite("Inky layer renderers")
struct InkyLayerRendererTests {
    let pageSize = CGSize(width: 816, height: 1056)

    func render<V: View>(_ view: V, size: CGSize) -> UIImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.uiImage ?? UIImage()
    }

    func renderAnnotation(_ action: InkyAction) -> (UIImage, CGRect) {
        let annotation = InkyAnnotation(action: action)
        let rect = InkyAnnotationGeometry.bounds(for: annotation, pageSize: pageSize).cgRect(in: pageSize)
        return (render(InkyAnnotationView(annotation: annotation, pageSize: pageSize, scale: 1), size: rect.size), rect)
    }

    func makeEditor(_ actions: [InkyAction]) -> PageEditorModel {
        let store = NotebookStore(rootURL: Fixtures.tempDirectory())
        let notebook = store.createNotebook(title: "Test", paper: .blank)
        let editor = PageEditorModel(notebookID: notebook.id, page: notebook.pages[0], store: store)
        actions.forEach { editor.addAnnotation($0, question: nil) }
        return editor
    }

    @Test func highlightFillsRegionWithItsColor() {
        let (image, rect) = renderAnnotation(.highlight(HighlightAction(region: NormRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05), color: .yellow, note: nil)))
        let p = image.pixel(at: CGPoint(x: rect.width / 2, y: rect.height / 2))
        #expect(p.a > 0.2)
        #expect(p.r > p.b + 0.1, "yellow: red channel dominates blue")
        #expect(image.coverage(in: CGRect(origin: .zero, size: rect.size).insetBy(dx: 4, dy: 4)) > 0.95)
    }

    @Test func circleDrawsARingNotAFill() {
        let (image, rect) = renderAnnotation(.circle(CircleAction(region: NormRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1), style: .solid)))
        #expect(image.pixel(at: CGPoint(x: rect.width / 2, y: rect.height / 2)).a < 0.05, "center stays clear")
        #expect(image.coverage(in: CGRect(origin: .zero, size: rect.size), step: 2) > 0.02, "ring is drawn")
    }

    @Test func starIsSolidAtItsCenter() {
        let (image, rect) = renderAnnotation(.star(StarAction(point: NormPoint(x: 0.5, y: 0.5))))
        #expect(rect.width == InkyAnnotationGeometry.starSize)
        #expect(image.pixel(at: CGPoint(x: rect.width / 2, y: rect.height / 2)).a > 0.9)
    }

    @Test func labelDrawsTextBoxAndStaysOnPage() {
        let label = LabelAction(anchor: NormPoint(x: 0.95, y: 0.02), text: "Rate-limiting step", arrow: true)
        let textRect = InkyAnnotationGeometry.labelTextRect(label, pageSize: pageSize)
        #expect(textRect.minX >= 0 && textRect.maxX <= 1 && textRect.minY >= 0 && textRect.maxY <= 1)
        #expect(textRect.maxX <= label.anchor.x, "flips to the left near the right edge")
        let (image, rect) = renderAnnotation(.label(label))
        #expect(image.coverage(in: CGRect(origin: .zero, size: rect.size)) > 0.1)
    }

    @Test func fillTextRendersInsideRegion() {
        let (image, rect) = renderAnnotation(.fillText(FillTextAction(region: NormRect(x: 0.5, y: 0.6, width: 0.3, height: 0.05), text: "x = 42", handwritingStyle: true)))
        let coverage = image.coverage(in: CGRect(origin: .zero, size: rect.size), step: 2)
        #expect(coverage > 0.01 && coverage < 0.8)
    }

    @Test func cardsGetAMinimumSizeAndRenderPlaceholders() {
        let tiny = NormRect(x: 0.9, y: 0.9, width: 0.01, height: 0.01)
        let card = InkyAnnotationGeometry.cardRect(near: tiny, pageSize: pageSize)
        #expect(card.width * pageSize.width >= InkyAnnotationGeometry.minCardSize.width - 0.5)
        #expect(card.maxX <= 0.99 + 1e-9 && card.maxY <= 0.99 + 1e-9, "pushed back onto the page")

        let (molecule, mRect) = renderAnnotation(.insertMoleculeCard(InsertMoleculeCardAction(smiles: "CCO", near: tiny, highlightGroups: [], starGroups: [], caption: nil)))
        #expect(molecule.pixel(at: CGPoint(x: mRect.width / 2, y: mRect.height / 2)).a > 0.9, "opaque card surface")
        let spec = GraphSpec(title: nil, xMin: -1, xMax: 1, yMin: -1, yMax: 1, functions: [.init(expression: "x", label: nil, color: nil)], params: [], asymptotes: [], points: [], labels: [])
        let (graph, gRect) = renderAnnotation(.insertGraphCard(InsertGraphCardAction(spec: spec, near: tiny)))
        #expect(graph.pixel(at: CGPoint(x: gRect.width / 2, y: gRect.height / 2)).a > 0.9)
    }

    @Test func layerPlacesAnnotationsAtPageCoordinates() {
        let region = NormRect(x: 0.1, y: 0.1, width: 0.4, height: 0.05)
        let editor = makeEditor([.highlight(HighlightAction(region: region, color: .blue, note: nil))])
        let image = render(InkyLayerView(editor: editor), size: pageSize)
        let inside = region.center.cgPoint(in: pageSize)
        #expect(image.pixel(at: inside).a > 0.2)
        #expect(image.pixel(at: CGPoint(x: pageSize.width * 0.8, y: pageSize.height * 0.8)).a < 0.01)
    }

    @Test func layerHonorsMoveHideAndVisibility() {
        let region = NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        let editor = makeEditor([.highlight(HighlightAction(region: region, color: .yellow, note: nil))])
        let id = editor.annotations[0].id
        editor.moveAnnotation(id, by: NormPoint(x: 0.5, y: 0.5))
        var image = render(InkyLayerView(editor: editor), size: pageSize)
        #expect(image.pixel(at: region.center.cgPoint(in: pageSize)).a < 0.01, "moved away")
        #expect(image.pixel(at: region.center.offsetBy(dx: 0.5, dy: 0.5).cgPoint(in: pageSize)).a > 0.2, "moved here")

        editor.setHidden(id, true)
        image = render(InkyLayerView(editor: editor), size: pageSize)
        #expect(image.pixel(at: region.center.offsetBy(dx: 0.5, dy: 0.5).cgPoint(in: pageSize)).a < 0.01)

        editor.setHidden(id, false)
        editor.showsInkyLayer = false
        #expect(editor.visibleAnnotations.isEmpty)
    }

    @Test func overlayClaimsTouchesOnlyOnAnnotations() {
        let editor = makeEditor([.star(StarAction(point: NormPoint(x: 0.5, y: 0.5)))])
        #expect(editor.overlayWantsTouch(at: NormPoint(x: 0.5, y: 0.5)))
        #expect(!editor.overlayWantsTouch(at: NormPoint(x: 0.1, y: 0.9)))
        editor.selectedAnnotationID = editor.annotations[0].id
        #expect(editor.overlayWantsTouch(at: NormPoint(x: 0.1, y: 0.9)), "selection captures taps to deselect")
    }

    @Test func editingReplacesTheRightField() {
        let annotation = InkyAnnotation(action: .label(LabelAction(anchor: NormPoint(x: 0.5, y: 0.5), text: "old", arrow: false)))
        let edited = InkyLayerView.replacingText(in: annotation, with: "new")
        guard case .label(let l) = edited.action else { Issue.record("expected label"); return }
        #expect(l.text == "new")
        #expect(InkyLayerView.editableText(of: .star(StarAction(point: NormPoint(x: 0, y: 0)))) == nil)
    }

    @Test func flatteningACardReplacesItWithAnImageAtTheSameFrameAndPersists() throws {
        let spec = GraphSpec(title: "f", xMin: -1, xMax: 1, yMin: -1, yMax: 1,
                             functions: [.init(expression: "x", label: nil, color: nil)], params: [], asymptotes: [], points: [], labels: [])
        let near = NormRect(x: 0.1, y: 0.5, width: 0.4, height: 0.28)
        let editor = makeEditor([.insertGraphCard(InsertGraphCardAction(spec: spec, near: near))])
        let annotation = editor.annotations[0]
        let frame = InkyAnnotationGeometry.bounds(for: annotation, pageSize: editor.page.size)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 28)).image { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 28))
        }

        editor.replaceAnnotationWithImage(annotation.id, image: image)

        #expect(editor.annotations.isEmpty)
        let placed = try #require(editor.page.images.first)
        #expect(abs(placed.frame.x - frame.x) < 1e-9 && abs(placed.frame.width - frame.width) < 1e-9)
        let reloaded = try #require(editor.store.notebook(id: editor.notebookID)?.pages.first)
        #expect(reloaded.images.map(\.frame) == [placed.frame])
        #expect(editor.store.annotations(for: reloaded.id, in: editor.notebookID).isEmpty)
    }
}
