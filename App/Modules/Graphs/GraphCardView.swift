import SwiftUI

/// Interactive graph card for `insertGraphCard`. The Inky layer creates it as
/// `GraphCardView(action:)` inside `InkyCardContainer`, sized to the card's frame.
///
/// - The plot is a JSXGraph board in an offline WKWebView (pan with one finger, pinch to zoom,
///   drag points, tap a curve to edit it). Sliders and editors are native SwiftUI.
/// - Persistence, resize and flatten go through `GraphCardHost` from the environment.
struct GraphCardView: View {
    let action: InsertGraphCardAction

    @Environment(\.graphCardHost) private var host
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = GraphCardModel()
    @State private var confirmFlatten = false
    @GestureState private var resizeDrag: CGSize = .zero

    static let defaultPageSize = CGSize(width: 816, height: 1056)
    private var pageSize: CGSize { host?.pageSize ?? Self.defaultPageSize }

    var body: some View {
        GeometryReader { geo in
            let k = scale(for: geo.size)
            card(k: k, size: geo.size)
                .onAppear {
                    model.host = host
                    model.load(action)
                    model.attachWeb()
                    model.configure(colorScheme: colorScheme, scale: k)
                }
                .onChange(of: k) { model.configure(colorScheme: colorScheme, scale: k) }
                .onChange(of: colorScheme) { model.configure(colorScheme: colorScheme, scale: k) }
        }
        .onChange(of: action) { model.load(action) }
        .confirmationDialog("Flatten this graph into the page?", isPresented: $confirmFlatten, titleVisibility: .visible) {
            Button("Flatten") { flatten() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It becomes a picture on the page and can't be edited anymore.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inky.card.graph")
    }

    /// View points per page point, so text keeps its size on paper at any zoom.
    private func scale(for size: CGSize) -> Double {
        let cardWidth = InkyAnnotationGeometry.cardRect(near: action.near, pageSize: pageSize).width * pageSize.width
        guard cardWidth > 0, size.width > 0 else { return 1 }
        return min(max(size.width / cardWidth, 0.3), 4)
    }

    private var theme: GraphTheme { model.currentTheme }

    // MARK: Layout

    private func card(k: Double, size: CGSize) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                board
                legend(k: k)
                    .padding(8 * k)
                    // A popover stays clear of the keyboard wherever the card sits on the page.
                    .popover(isPresented: Binding(
                        get: { model.editingFunction != nil },
                        set: { if !$0 { model.finishEditing() } }
                    ), arrowEdge: .top) {
                        GraphExpressionEditor(model: model)
                    }
            }
            .overlay(alignment: .topTrailing) { toolbar(k: k).padding(6 * k) }
            .overlay(alignment: .bottom) { errorBanner(k: k) }
            .clipped()

            if let spec = model.spec, !spec.params.isEmpty {
                GraphParamSliders(model: model, k: k, maxHeight: size.height * 0.42)
            }
        }
        .background(GraphTheme.color(theme.background))
        .environment(\.colorScheme, theme.dark ? .dark : .light)
        .overlay(alignment: .bottomLeading) { asymptoteSummary }
        .overlay(alignment: .topLeading) { resizePreview(size: size, k: k) }
        .overlay(alignment: .bottomTrailing) { resizeHandle(size: size, k: k) }
    }

    /// The board is a canvas to VoiceOver; this names its asymptotes ("x = 3, y = 2") and says how
    /// many came from Inky (vs. detected on the curve).
    @ViewBuilder private var asymptoteSummary: some View {
        let lines = model.analysis.asymptotes
        if model.options.asymptotes, !lines.isEmpty {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Asymptotes: " + lines.map(\.label).joined(separator: ", "))
                .accessibilityValue("\(lines.filter { !$0.isAuto }.count) from Inky")
                .accessibilityIdentifier("inky.graph.asymptotes")
        }
    }

    private var board: some View {
        ZStack {
            if !model.boardReady {
                // Native drawing until the board is up (and wherever web views can't render).
                placeholder
            }
            if let web = model.web {
                GraphWebView(controller: web)
                    .opacity(model.boardReady ? 1 : 0.01)
            }
        }
    }

    private var placeholder: some View {
        let document = model.document ?? GraphDocument(spec: action.spec)
        let scene = model.scene() ?? GraphScene(document: document, theme: theme)
        return GraphPlotView(document: document, scene: scene)
    }

    private func legend(k: Double) -> some View {
        VStack(alignment: .leading, spacing: 4 * k) {
            if let doc = model.document {
                ForEach(doc.spec.functions.indices, id: \.self) { i in
                    Button { model.beginEditing(function: i) } label: {
                        HStack(spacing: 5 * k) {
                            Circle()
                                .fill(GraphTheme.color(GraphPalette.color(for: doc.spec.functions[i].color, index: i, dark: theme.dark)))
                                .frame(width: 7 * k, height: 7 * k)
                            Text("\(doc.functionName(at: i)) = \(GraphExpressionDisplay.pretty(doc.spec.functions[i].expression))")
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if doc.error(at: i) != nil {
                                Image(systemName: "exclamationmark.circle")
                            }
                        }
                        .font(.system(size: 11 * k, weight: .medium, design: .rounded))
                        .foregroundStyle(GraphTheme.color(theme.text))
                        .padding(.horizontal, 7 * k)
                        .padding(.vertical, 3 * k)
                        .background(Capsule().fill(GraphTheme.color(theme.background).opacity(0.88)))
                        .overlay(Capsule().strokeBorder(GraphTheme.color(theme.grid), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 260 * k, alignment: .leading)
                    .accessibilityIdentifier("inky.graph.function.\(i)")
                    .accessibilityLabel("Edit \(doc.functionName(at: i))")
                    .accessibilityValue(doc.spec.functions[i].expression)
                }
            }
        }
    }

    private func toolbar(k: Double) -> some View {
        HStack(spacing: 4 * k) {
            toolButton("minus.magnifyingglass", k: k, id: "inky.graph.zoomOut", label: "Zoom out") { model.zoom(in: false) }
            toolButton("plus.magnifyingglass", k: k, id: "inky.graph.zoomIn", label: "Zoom in") { model.zoom(in: true) }
            toolButton("arrow.up.left.and.down.right.magnifyingglass", k: k, id: "inky.graph.fit", label: "Fit view") { model.fitView() }
            Menu {
                menuContent
            } label: {
                toolIcon("ellipsis", k: k)
            }
            .accessibilityIdentifier("inky.graph.menu")
            .accessibilityLabel("Graph options")
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Button { model.addFunction() } label: { Label("Add function", systemImage: "plus") }
        Menu {
            ForEach(GraphPreset.Subject.allCases, id: \.self) { subject in
                Section(subject.rawValue) {
                    ForEach(GraphPresets.all.filter { $0.subject == subject }) { preset in
                        Button(preset.title) { model.applyPreset(preset) }
                    }
                }
            }
        } label: { Label("Presets", systemImage: "square.grid.2x2") }
        Section("Show") {
            Toggle("Asymptotes", isOn: $model.options.asymptotes)
            Toggle("Intercepts & turning points", isOn: $model.options.features)
        }
        Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0, colorScheme: colorScheme) })) {
            ForEach(GraphCardModel.Appearance.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.menu)
        if host?.flatten != nil {
            Divider()
            Button { confirmFlatten = true } label: { Label("Flatten into page", systemImage: "photo") }
        }
    }

    private func toolButton(_ systemImage: String, k: Double, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolIcon(systemImage, k: k) }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
            .accessibilityLabel(label)
    }

    private func toolIcon(_ systemImage: String, k: Double) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 11 * k, weight: .semibold))
            .foregroundStyle(GraphTheme.color(theme.text))
            .frame(width: 24 * k, height: 24 * k)
            .background(Circle().fill(GraphTheme.color(theme.background).opacity(0.9)))
            .overlay(Circle().strokeBorder(GraphTheme.color(theme.grid), lineWidth: 1))
            .contentShape(Circle())
    }

    @ViewBuilder
    private func errorBanner(k: Double) -> some View {
        if let message = model.boardError {
            Text("The graph couldn't draw: \(message)")
                .font(.system(size: 10 * k, design: .rounded))
                .foregroundStyle(GraphTheme.color(theme.text))
                .padding(6 * k)
                .background(RoundedRectangle(cornerRadius: 6 * k).fill(GraphTheme.color(theme.background).opacity(0.9)))
                .padding(6 * k)
        }
    }

    // MARK: Resize & flatten

    @ViewBuilder
    private func resizeHandle(size: CGSize, k: Double) -> some View {
        if host != nil {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 9 * k, weight: .bold))
                .foregroundStyle(GraphTheme.color(theme.muted))
                .frame(width: 22 * k, height: 22 * k)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .updating($resizeDrag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let card = model.cardRect(pageSize: pageSize).cgRect(in: pageSize)
                            let w = card.width * k, h = card.height * k
                            guard w > 0, h > 0 else { return }
                            model.resize(by: CGSize(width: (w + value.translation.width) / w, height: (h + value.translation.height) / h), pageSize: pageSize)
                        }
                )
                .accessibilityIdentifier("inky.graph.resize")
                .accessibilityLabel("Resize graph")
        }
    }

    @ViewBuilder
    private func resizePreview(size: CGSize, k: Double) -> some View {
        if resizeDrag != .zero {
            RoundedRectangle(cornerRadius: 8 * k)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: max(40, size.width + resizeDrag.width), height: max(40, size.height + resizeDrag.height))
                .allowsHitTesting(false)
        }
    }

    private func flatten() {
        guard let flatten = host?.flatten, let image = model.flattenedImage(pageSize: pageSize) else { return }
        model.persistNow()
        flatten(image)
    }
}
