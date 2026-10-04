import PencilKit
import UIKit

/// Owns the PKToolPicker for a notebook (so tool choice survives page changes) and the
/// custom "Inky" item that summons Inky instead of drawing.
@MainActor
final class InkyToolPickerHost: NSObject, PKToolPickerObserver {
    static let inkyItemIdentifier = "com.heyinky.tool.inky"
    static let selectItemIdentifier = "com.heyinky.tool.select"
    static let textItemIdentifier = "com.heyinky.tool.text"
    /// Bump when the set of tool items changes (see `migrateSavedLayout`).
    static let layoutVersion = 3

    let picker: PKToolPicker
    /// Called when the user picks the Inky item in the tool picker.
    var onInkySelected: (() -> Void)?
    /// Called when the user switches from the Inky item to a drawing tool.
    var onInkyDeselected: (() -> Void)?
    /// The Select tool was picked (true) or left (false).
    var onSelectToolChanged: ((Bool) -> Void)?
    /// The Text tool was picked (true) or left (false).
    var onTextToolChanged: ((Bool) -> Void)?
    private var wasInkySelected = false
    private var wasSelectSelected = false
    private var wasTextSelected = false

    private var previousIdentifier: String?
    private var lastDrawingIdentifier: String?
    private var eraserReturnIdentifier: String?
    private var suppressCallbacks = false
    private weak var canvas: PKCanvasView?

    /// PencilKit restores the picker's saved state (tools, eraser mode) when it's created, over
    /// the items we pass in. When our layout changes, forget the old saved state once so the new
    /// defaults apply (our Select instead of PencilKit's lasso, pixel eraser). The student's
    /// choices are saved again from then on.
    static func migrateSavedLayout(_ defaults: UserDefaults = .standard) {
        let key = "HeyInkyToolPickerLayoutVersion"
        guard defaults.integer(forKey: key) < layoutVersion else { return }
        defaults.removeObject(forKey: "PKPaletteNamedDefaults")
        defaults.set(layoutVersion, forKey: key)
    }

    override init() {
        Self.migrateSavedLayout()
        var config = PKToolPickerCustomItem.Configuration(identifier: Self.inkyItemIdentifier, name: "Inky")
        config.imageProvider = { _ in
            let symbol = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
            return UIImage(systemName: "sparkles", withConfiguration: symbol)?
                .withTintColor(Theme.accentUI, renderingMode: .alwaysOriginal) ?? UIImage()
        }
        config.allowsColorSelection = false
        let inkyItem = PKToolPickerCustomItem(configuration: config)

        // Our own Select tool (PencilKit's lasso can't select images or Inky's marks, and its
        // selection isn't public API): select, move, resize, copy/paste, ask Inky.
        var selectConfig = PKToolPickerCustomItem.Configuration(identifier: Self.selectItemIdentifier, name: "Select")
        selectConfig.imageProvider = { _ in
            let symbol = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            return UIImage(systemName: "lasso", withConfiguration: symbol)?
                .withTintColor(.label, renderingMode: .alwaysOriginal) ?? UIImage()
        }
        selectConfig.allowsColorSelection = false
        let selectItem = PKToolPickerCustomItem(configuration: selectConfig)

        // Typed text boxes.
        var textConfig = PKToolPickerCustomItem.Configuration(identifier: Self.textItemIdentifier, name: "Text")
        textConfig.imageProvider = { _ in
            let symbol = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
            return UIImage(systemName: "textformat", withConfiguration: symbol)?
                .withTintColor(.label, renderingMode: .alwaysOriginal) ?? UIImage()
        }
        textConfig.allowsColorSelection = false
        let textItem = PKToolPickerCustomItem(configuration: textConfig)

        picker = PKToolPicker(toolItems: [
            PKToolPickerInkingItem(type: .pen),
            PKToolPickerInkingItem(type: .marker),
            PKToolPickerInkingItem(type: .pencil),
            // Pixel eraser by default (rubs out part of a stroke); the picker still offers object erase.
            PKToolPickerEraserItem(type: .bitmap),
            selectItem,
            textItem,
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

    var isSelectSelected: Bool {
        picker.selectedToolItemIdentifier == Self.selectItemIdentifier
    }

    var isTextSelected: Bool {
        picker.selectedToolItemIdentifier == Self.textItemIdentifier
    }

    /// Select/Text aren't drawing tools: Inky returns to the last pen, not to them.
    private var isModeToolSelected: Bool { isSelectSelected || isTextSelected }

    /// Mirrors Inky mode in the picker (e.g. when summoned from the button or a squeeze).
    func setInkySelected(_ selected: Bool) {
        guard selected != isInkySelected else { return }
        suppressCallbacks = true
        defer { suppressCallbacks = false }
        if selected {
            if !isModeToolSelected { lastDrawingIdentifier = picker.selectedToolItemIdentifier }
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
        defer {
            wasInkySelected = isInkySelected
            wasSelectSelected = isSelectSelected
            wasTextSelected = isTextSelected
        }
        if isSelectSelected != wasSelectSelected { onSelectToolChanged?(isSelectSelected) }
        if isTextSelected != wasTextSelected { onTextToolChanged?(isTextSelected) }
        guard !suppressCallbacks else { return }
        if isInkySelected {
            onInkySelected?()
        } else {
            if !isModeToolSelected {
                previousIdentifier = lastDrawingIdentifier
                lastDrawingIdentifier = toolPicker.selectedToolItemIdentifier
            }
            if wasInkySelected { onInkyDeselected?() }
        }
    }
}
