import SwiftUI

/// State behind one graph card: the editable document, the web board, inline editors, and
/// write-back to the page through `GraphCardHost`.
@MainActor
@Observable
final class GraphCardModel {
    enum Appearance: String, CaseIterable, Sendable {
        case automatic = "Automatic", light = "Light", dark = "Dark"
    }

    private(set) var document: GraphDocument?
    private(set) var analysis = GraphAnalysis.Result()
    private(set) var near = NormRect.zero
    var options = GraphScene.Options() { didSet { pushScene() } }
    var appearance: Appearance = .automatic

    // Inline expression editor
    private(set) var editingFunction: Int?
    var draft = ""
    private(set) var draftError: GraphExpressionError?
    private var draftOriginal: String?

    /// Slider whose range editor is open.
    var editingParam: Int?
    /// Set when the board finished drawing (the native placeholder hides).
    private(set) var boardReady = false
    private(set) var boardError: String?

    @ObservationIgnored private(set) var web: GraphWebController?
    @ObservationIgnored var host: GraphCardHost?
    @ObservationIgnored private var theme = GraphTheme.light
    @ObservationIgnored private var scale: Double = 1
    @ObservationIgnored private var lastKnownAction: InsertGraphCardAction?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    static let persistDelay: Duration = .milliseconds(400)

    var spec: GraphSpec? { document?.spec }

    // MARK: Loading

    /// Adopts `action` unless it's the one this card last wrote (avoids reload loops).
    func load(_ action: InsertGraphCardAction) {
        guard action != lastKnownAction else { return }
        lastKnownAction = action
        near = action.near
        document = GraphDocument(spec: action.spec)
        cancelEditing()
        refreshAnalysis()
        pushScene()
    }

    /// Creates the web board on first appearance.
    func attachWeb() {
        guard web == nil else { return }
        let controller = GraphWebController()
        controller.onMessage = { [weak self] in self?.handle($0) }
        web = controller
        pushScene()
    }

    func configure(colorScheme: ColorScheme, scale: Double) {
        let effective: ColorScheme = switch appearance {
        case .automatic: colorScheme
        case .light: .light
        case .dark: .dark
        }
        let newTheme = GraphTheme.for(effective)
        guard newTheme != theme || abs(scale - self.scale) > 0.001 else { return }
        theme = newTheme
        self.scale = scale
        pushScene()
    }

    var currentTheme: GraphTheme { theme }

    func scene() -> GraphScene? {
        guard let document else { return nil }
        return GraphScene(document: document, theme: theme, scale: scale, options: options, analysis: analysis)
    }

    private func pushScene() {
        guard let web, let scene = scene() else { return }
        web.show(scene)
    }

    private func refreshAnalysis() {
        analysis = document?.analysis() ?? GraphAnalysis.Result()
    }

    /// Applies a document change: re-analyzes, redraws, and persists after a short pause.
    private func commit(_ change: (inout GraphDocument) -> Void, persist: Bool = true, redraw: Bool = true) {
        guard var doc = document else { return }
        change(&doc)
        guard doc != document else { return }
        document = doc
        refreshAnalysis()
        if redraw { pushScene() }
        if persist { schedulePersist() }
    }

    // MARK: Web messages

    func handle(_ message: GraphWebMessage) {
        switch message {
        case .rendered:
            boardReady = true
            boardError = nil
        case .view(let w, let final):
            guard final else { return }
            commit { $0.setWindow(w) }
        case .point(let i, let x, let y, let final):
            commit({ $0.movePoint(at: i, x: x, y: y) }, persist: final, redraw: false)
        case .tapFunction(let i):
            beginEditing(function: i)
        case .error(let message):
            boardError = message
        case .ready:
            break
        }
    }

    // MARK: Sliders

    func setParam(_ index: Int, to value: Double) {
        commit { $0.setParamValue(value, at: index) }
    }

    func setParamRange(_ index: Int, min: Double, max: Double, step: Double?) throws(GraphDocument.RangeError) {
        guard var doc = document else { return }
        try doc.setParamRange(at: index, min: min, max: max, step: step)
        commit { $0 = doc }
    }

    func removeParam(_ index: Int) {
        editingParam = nil
        commit { $0.removeParam(at: index) }
    }

    // MARK: Expression editing

    func beginEditing(function index: Int) {
        guard let doc = document, doc.spec.functions.indices.contains(index) else { return }
        if editingFunction != nil { finishEditing() }
        editingFunction = index
        draftOriginal = doc.spec.functions[index].expression
        draft = GraphExpressionDisplay.pretty(doc.spec.functions[index].expression)
        draftError = doc.error(at: index)
    }

    /// Live: valid drafts redraw immediately; invalid ones keep the last good curve.
    func draftChanged() {
        guard let index = editingFunction, let doc = document else { return }
        switch doc.validate(draft) {
        case .success:
            draftError = nil
            commit({ try? $0.setExpression(draft, at: index) }, persist: false)
        case .failure(let error):
            draftError = error
        }
    }

    func addSliderForDraftUnknown() {
        guard let name = draftError?.unknownIdentifier else { return }
        commit { $0.addParam(named: name) }
        draftChanged()
    }

    func finishEditing() {
        guard let index = editingFunction else { return }
        if draftError == nil { commit { try? $0.setExpression(draft, at: index) } }
        else if let original = draftOriginal { commit({ try? $0.setExpression(original, at: index) }, persist: false) }
        schedulePersist()
        cancelEditing()
    }

    func cancelDraft() {
        if let index = editingFunction, let original = draftOriginal {
            commit({ try? $0.setExpression(original, at: index) }, persist: false)
        }
        cancelEditing()
    }

    private func cancelEditing() {
        editingFunction = nil
        draftOriginal = nil
        draftError = nil
        draft = ""
    }

    func deleteEditedFunction() {
        guard let index = editingFunction else { return }
        cancelEditing()
        commit { $0.removeFunction(at: index) }
    }

    func addFunction() {
        guard let doc = document else { return }
        var index = 0
        commit { index = (try? $0.addFunction("x")) ?? doc.spec.functions.count }
        beginEditing(function: index)
    }

    // MARK: View

    func zoom(in zoomIn: Bool) { web?.zoom(in: zoomIn) }

    func fitView() {
        guard let doc = document else { return }
        let fitted = doc.fittedWindow()
        commit { $0.setWindow(fitted) }
        web?.setView(fitted)
    }

    func applyPreset(_ preset: GraphPreset) {
        cancelEditing()
        commit { $0 = GraphDocument(spec: preset.spec) }
        if let doc = document { web?.setView(doc.window) }
    }

    func setAppearance(_ appearance: Appearance, colorScheme: ColorScheme) {
        self.appearance = appearance
        configure(colorScheme: colorScheme, scale: scale)
    }

    // MARK: Card frame (resize) and flatten

    /// Card frame in normalized page space, matching how the Inky layer places it.
    func cardRect(pageSize: CGSize) -> NormRect {
        InkyAnnotationGeometry.cardRect(near: near, pageSize: pageSize)
    }

    /// Resizes by a factor (from the corner handle); the top-left corner stays put.
    func resize(by factor: CGSize, pageSize: CGSize) {
        let base = cardRect(pageSize: pageSize)
        let minW = InkyAnnotationGeometry.minCardSize.width / pageSize.width
        let minH = InkyAnnotationGeometry.minCardSize.height / pageSize.height
        let w = min(max(base.width * factor.width, minW), 0.98 - base.x)
        let h = min(max(base.height * factor.height, minH), 0.98 - base.y)
        near = NormRect(x: base.x, y: base.y, width: max(w, minW), height: max(h, minH))
        persistNow()
    }

    /// The card as a standalone image (legend + slider values), in page points × `pixelScale`.
    func flattenedImage(pageSize: CGSize, pixelScale: CGFloat = 3) -> UIImage? {
        guard let doc = document else { return nil }
        let rect = cardRect(pageSize: pageSize).cgRect(in: pageSize)
        let scene = GraphScene(document: doc, theme: .light, scale: 1, options: options, analysis: analysis)
        return GraphPlotView.image(document: doc, scene: scene, size: rect.size, scale: pixelScale)
    }

    // MARK: Persistence

    var action: InsertGraphCardAction? {
        document.map { InsertGraphCardAction(spec: $0.spec, near: near) }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: Self.persistDelay)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    func persistNow() {
        persistTask?.cancel()
        guard let action, action != lastKnownAction else { return }
        lastKnownAction = action
        host?.update(action)
    }
}
