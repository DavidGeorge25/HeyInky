import PencilKit
import SwiftUI
import UIKit

/// Hosts one page: PKCanvasView (ink, zoom, scroll) with three views riding along inside
/// its scroll content, all sized to page size × zoom:
///   1. PageBackgroundView (paper / PDF / images) below the ink
///   2. LassoCaptureView above the ink, active only while Inky is summoned
/// The Inky layer (SwiftUI) is a sibling *above* the canvas whose frame tracks the
/// canvas's scroll and zoom (PKCanvasView hides its subviews from accessibility, and this
/// keeps annotation touches away from PencilKit). It is touch-transparent except on
/// annotations.
@MainActor
final class PageCanvasController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    let editor: PageEditorModel
    let tools: InkyToolPickerHost
    /// Called with a location (in this view's coordinates) when the user summons Inky
    /// from the Pencil (squeeze) or the tool picker.
    var onSummon: ((CGPoint?) -> Void)?

    let canvas = PageInkCanvasView()
    private let backgroundView = PageBackgroundView()
    private let overlayContainer = PassthroughView()
    private let lassoView = LassoCaptureView()
    private var inkyHost: UIHostingController<InkyLayerView>?
    private var lastLayoutWidth: CGFloat = 0
    private var lastBackgroundZoom: CGFloat = 0

    init(editor: PageEditorModel, tools: InkyToolPickerHost) {
        self.editor = editor
        self.tools = tools
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var pageSize: CGSize { editor.page.size }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.canvasBackgroundUI

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = .default
        canvas.alwaysBounceVertical = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = self
        canvas.pageUndoManager = editor.undoManager
        canvas.drawing = editor.drawing
        canvas.accessibilityIdentifier = "page.canvas"
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        backgroundView.configure(editor: editor)
        backgroundView.layer.shadowColor = UIColor.black.cgColor
        backgroundView.layer.shadowOpacity = 0.08
        backgroundView.layer.shadowRadius = 10
        backgroundView.layer.shadowOffset = CGSize(width: 0, height: 3)
        canvas.insertSubview(backgroundView, at: 0)

        let host = UIHostingController(rootView: InkyLayerView(editor: editor))
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        host.safeAreaRegions = []
        addChild(host)
        overlayContainer.addSubview(host.view)
        host.didMove(toParent: self)
        inkyHost = host
        overlayContainer.wantsTouch = { [weak self] point in
            guard let self, self.overlayContainer.bounds.width > 0 else { return false }
            return self.editor.overlayWantsTouch(at: NormPoint(
                x: point.x / self.overlayContainer.bounds.width,
                y: point.y / self.overlayContainer.bounds.height
            ))
        }
        view.addSubview(overlayContainer)
        view.clipsToBounds = true

        lassoView.isUserInteractionEnabled = false
        lassoView.onLassoChanged = { [weak self] path, finished in
            guard let self else { return }
            let size = self.lassoView.bounds.size
            guard size.width > 0, finished else { return }
            self.editor.setLasso(path: path.map { NormPoint(x: $0.x / size.width, y: $0.y / size.height) })
        }
        canvas.addSubview(lassoView)

        let imageTap = UITapGestureRecognizer(target: self, action: #selector(handleImageTap(_:)))
        imageTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        imageTap.cancelsTouchesInView = false
        canvas.addGestureRecognizer(imageTap)

        let pencil = UIPencilInteraction(delegate: self)
        view.addInteraction(pencil)

        editor.canvasController = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        tools.attach(to: canvas)
        tools.onInkySelected = { [weak self] in self?.onSummon?(nil) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        editor.flush()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 0 else { return }
        if abs(width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = width
            let fit = (width - 48) / pageSize.width
            canvas.minimumZoomScale = fit * 0.6
            canvas.maximumZoomScale = fit * 5
            canvas.zoomScale = fit
        }
        layoutContent()
    }

    /// Sizes the riding views to page × zoom and centers the page horizontally.
    private func layoutContent() {
        let zoom = canvas.zoomScale
        let size = CGSize(width: pageSize.width * zoom, height: pageSize.height * zoom)
        canvas.contentSize = size
        let frame = CGRect(origin: .zero, size: size)
        backgroundView.frame = frame
        lassoView.frame = frame
        let horizontal = max(0, (canvas.bounds.width - size.width) / 2)
        canvas.contentInset = UIEdgeInsets(top: 24, left: horizontal, bottom: 120, right: horizontal)
        if abs(zoom - lastBackgroundZoom) > 0.001, !canvas.isZooming {
            lastBackgroundZoom = zoom
            // Keep the backing bitmap bounded when zoomed far in.
            let screenScale = view.window?.screen.scale ?? 2
            backgroundView.contentScaleFactor = min(screenScale, 4096 / max(size.width, 1))
            backgroundView.setNeedsDisplay()
        }
        positionOverlay()
    }

    /// Keeps the Inky layer exactly over the page as the canvas scrolls and zooms.
    private func positionOverlay() {
        let frame = canvas.convert(backgroundView.frame, to: view)
        if overlayContainer.frame != frame {
            overlayContainer.frame = frame
            inkyHost?.view.frame = overlayContainer.bounds
        }
    }

    // MARK: Model -> view

    /// Called from SwiftUI when observed editor state changes.
    func sync() {
        let inky = editor.isInkyMode
        lassoView.isUserInteractionEnabled = inky
        canvas.drawingGestureRecognizer.isEnabled = !inky
        canvas.panGestureRecognizer.minimumNumberOfTouches = inky ? 2 : 1
        lassoView.setRegion(editor.lassoPath.isEmpty ? nil : editor.lassoPath.map {
            CGPoint(x: $0.x * lassoView.bounds.width, y: $0.y * lassoView.bounds.height)
        }, active: inky)
        tools.setInkySelected(inky)
        backgroundView.setNeedsDisplay()
    }


    /// Where on screen (this view's coordinates) a normalized page point is.
    func viewPoint(for point: NormPoint) -> CGPoint {
        let p = point.cgPoint(in: overlayContainer.bounds.size)
        return overlayContainer.convert(p, to: view)
    }

    /// The page point (page points, may lie outside the page) under a point in this view.
    func pagePoint(forViewPoint point: CGPoint) -> CGPoint {
        let p = view.convert(point, to: overlayContainer)
        let bounds = overlayContainer.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: p.x / bounds.width * editor.page.width, y: p.y / bounds.height * editor.page.height)
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        editor.drawingDidChange(canvasView.drawing)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        positionOverlay()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        layoutContent()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        layoutContent()
        backgroundView.setNeedsDisplay()
    }

    // MARK: Images

    @objc private func handleImageTap(_ gesture: UITapGestureRecognizer) {
        guard !editor.isInkyMode, overlayContainer.bounds.width > 0 else { return }
        let p = gesture.location(in: overlayContainer)
        let point = NormPoint(x: p.x / overlayContainer.bounds.width, y: p.y / overlayContainer.bounds.height)
        if let image = editor.image(at: point), editor.selectedAnnotationID == nil {
            editor.selectedImageID = image.id
        }
    }

    // MARK: UIPencilInteractionDelegate

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        onSummon?(squeeze.hoverPose?.location)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser: tools.toggleEraser()
        case .switchPrevious: tools.selectPrevious()
        case .showColorPalette, .showInkAttributes, .showContextualPalette: tools.show(for: canvas)
        default: break
        }
    }
}

/// Paper / PDF / images, redrawn at the current zoom for crisp output.
/// PencilKit registers stroke undo on the canvas's `undoManager`. Each page uses its editor's
/// manager (shared with Inky annotation changes) instead of the window's.
final class PageInkCanvasView: PKCanvasView {
    weak var pageUndoManager: UndoManager?
    override var undoManager: UndoManager? { pageUndoManager ?? super.undoManager }
}

final class PageBackgroundView: UIView {
    private weak var editor: PageEditorModel?

    func configure(editor: PageEditorModel) {
        self.editor = editor
        isUserInteractionEnabled = false
        backgroundColor = .white
        contentMode = .scaleToFill
    }

    override func draw(_ rect: CGRect) {
        guard let editor, let context = UIGraphicsGetCurrentContext() else { return }
        PageRenderer.drawBackground(page: editor.page, notebookID: editor.notebookID, store: editor.store, in: bounds, context: context)
    }
}

/// Passes touches through unless `wantsTouch` claims the point.
final class PassthroughView: UIView {
    var wantsTouch: ((CGPoint) -> Bool)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return wantsTouch?(point) == true ? hit : nil
    }
}

/// Captures a freeform lasso loop while Inky is summoned and shows the selected region.
final class LassoCaptureView: UIView {
    var onLassoChanged: (([CGPoint], Bool) -> Void)?
    private var points: [CGPoint] = []
    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shape.fillColor = Theme.accentUI.withAlphaComponent(0.06).cgColor
        shape.strokeColor = Theme.accentUI.cgColor
        shape.lineWidth = 2
        shape.lineDashPattern = [7, 5]
        shape.lineCap = .round
        shape.lineJoin = .round
        layer.addSublayer(shape)
        accessibilityIdentifier = "inky.lasso"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setRegion(_ path: [CGPoint]?, active: Bool) {
        guard points.isEmpty else { return } // don't fight an in-progress stroke
        shape.path = path.map(Self.closedPath)
        shape.isHidden = !active
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        points = [touch.location(in: self)]
        updateShape(closed: false)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        points.append(contentsOf: coalesced.map { $0.location(in: self) })
        updateShape(closed: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish()
    }

    private func finish() {
        let finished = points
        points = []
        guard finished.count > 3 else {
            shape.path = nil
            return
        }
        shape.path = Self.closedPath(finished)
        onLassoChanged?(finished, true)
    }

    private func updateShape(closed: Bool) {
        shape.isHidden = false
        let path = UIBezierPath()
        guard let first = points.first else { return }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        if closed { path.close() }
        shape.path = path.cgPath
    }

    private static func closedPath(_ points: [CGPoint]) -> CGPath {
        let path = UIBezierPath()
        guard let first = points.first else { return path.cgPath }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        path.close()
        return path.cgPath
    }
}

/// SwiftUI wrapper. Recreated per page (`.id(page.id)`).
struct PageCanvasRepresentable: UIViewControllerRepresentable {
    let editor: PageEditorModel
    let tools: InkyToolPickerHost
    var onSummon: (CGPoint?) -> Void

    func makeUIViewController(context: Context) -> PageCanvasController {
        let controller = PageCanvasController(editor: editor, tools: tools)
        controller.onSummon = onSummon
        return controller
    }

    func updateUIViewController(_ controller: PageCanvasController, context: Context) {
        // Reading these registers Observation tracking, so SwiftUI calls us when they change.
        _ = editor.isInkyMode
        _ = editor.lassoPath
        _ = editor.page
        controller.onSummon = onSummon
        controller.sync()
    }
}
