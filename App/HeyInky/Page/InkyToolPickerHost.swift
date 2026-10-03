import PencilKit
import UIKit

/// Owns the PKToolPicker for a notebook (so tool choice survives page changes) and the
/// custom "Inky" item that summons Inky instead of drawing.
@MainActor
final class InkyToolPickerHost: NSObject, PKToolPickerObserver {
    static let inkyItemIdentifier = "com.heyinky.tool.inky"

    let picker: PKToolPicker
    /// Called when the user picks the Inky item in the tool picker.
    var onInkySelected: (() -> Void)?
    /// Called when the user switches from the Inky item to a drawing tool.
    var onInkyDeselected: (() -> Void)?
    private var wasInkySelected = false

    private var previousIdentifier: String?
    private var lastDrawingIdentifier: String?
    private var eraserReturnIdentifier: String?
    private var suppressCallbacks = false
    private weak var canvas: PKCanvasView?

    override init() {
        var config = PKToolPickerCustomItem.Configuration(identifier: Self.inkyItemIdentifier, name: "Inky")
        config.imageProvider = { _ in
            let symbol = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
            return UIImage(systemName: "sparkles", withConfiguration: symbol)?
                .withTintColor(Theme.accentUI, renderingMode: .alwaysOriginal) ?? UIImage()
        }
        config.allowsColorSelection = false
        let inkyItem = PKToolPickerCustomItem(configuration: config)

        picker = PKToolPicker(toolItems: [
            PKToolPickerInkingItem(type: .pen),
            PKToolPickerInkingItem(type: .marker),
            PKToolPickerInkingItem(type: .pencil),
            PKToolPickerEraserItem(type: .vector),
            PKToolPickerLassoItem(),
            PKToolPickerRulerItem(),
            inkyItem,
        ])
        super.init()
        picker.addObserver(self)
    }

    func attach(to canvas: PKCanvasView) {
        if let old = self.canvas, old !== canvas {
            picker.removeObserver(old)
        }
        self.canvas = canvas
        picker.addObserver(canvas)
        show(for: canvas)
    }

    func show(for canvas: PKCanvasView) {
        picker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    var isInkySelected: Bool {
        picker.selectedToolItemIdentifier == Self.inkyItemIdentifier
    }

    /// Mirrors Inky mode in the picker (e.g. when summoned from the button or a squeeze).
    func setInkySelected(_ selected: Bool) {
        guard selected != isInkySelected else { return }
        suppressCallbacks = true
        defer { suppressCallbacks = false }
        if selected {
            lastDrawingIdentifier = picker.selectedToolItemIdentifier
            picker.selectedToolItemIdentifier = Self.inkyItemIdentifier
        } else {
            picker.selectedToolItemIdentifier = lastDrawingIdentifier ?? picker.toolItems.first?.identifier ?? ""
        }
    }

    func toggleEraser() {
        let eraser = picker.toolItems.first { $0 is PKToolPickerEraserItem }?.identifier
        guard let eraser else { return }
        if picker.selectedToolItemIdentifier == eraser {
            picker.selectedToolItemIdentifier = eraserReturnIdentifier ?? picker.toolItems.first?.identifier ?? eraser
        } else {
            eraserReturnIdentifier = picker.selectedToolItemIdentifier
            picker.selectedToolItemIdentifier = eraser
        }
    }

    func selectPrevious() {
        guard let previous = previousIdentifier else { return }
        let current = picker.selectedToolItemIdentifier
        picker.selectedToolItemIdentifier = previous
        previousIdentifier = current
    }

    // MARK: PKToolPickerObserver

    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        defer { wasInkySelected = isInkySelected }
        guard !suppressCallbacks else { return }
        if isInkySelected {
            onInkySelected?()
        } else {
            previousIdentifier = lastDrawingIdentifier
            lastDrawingIdentifier = toolPicker.selectedToolItemIdentifier
            if wasInkySelected { onInkyDeselected?() }
        }
    }
}
