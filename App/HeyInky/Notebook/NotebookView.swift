import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One notebook: page canvas, page strip, Inky (button, popover, toast, sidebar).
struct NotebookView: View {
    let notebookID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    @State private var pageIndex = 0
    @State private var editor: PageEditorModel?
    @State private var session: InkySession
    @State private var tools = InkyToolPickerHost()
    @State private var showsPages = false
    @State private var importMode: ImportMode?
    @State private var photoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var confirmDeletePage = false

    enum ImportMode: Identifiable {
        case pdf, image
        var id: Self { self }
        var types: [UTType] { self == .pdf ? [.pdf] : [.image] }
    }

    init(notebookID: UUID, client: any InkyModelClient) {
        self.notebookID = notebookID
        _session = State(initialValue: InkySession(client: client))
    }

    private var notebook: Notebook? { app.store.notebook(id: notebookID) }

    var body: some View {
        HStack(spacing: 0) {
            if showsPages, let notebook {
                PageStrip(notebook: notebook, selection: $pageIndex) { index in
                    app.store.addPage(to: notebookID, at: index)
                    pageIndex = index
                }
                .transition(.move(edge: .leading))
            }

            ZStack {
                Theme.canvasBackground.ignoresSafeArea()
                if let editor {
                    pageArea(editor: editor)
                }
            }

            if let content = session.sidebar {
                InkySidebarView(content: content, speech: session.speechOutput) {
                    withAnimation(.snappy) { session.sidebar = nil }
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy, value: showsPages)
        .animation(.snappy, value: session.sidebar)
        .navigationTitle(notebook?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear {
            session.notebookTitle = notebook?.title
            loadPage()
        }
        .onChange(of: pageIndex) { _, _ in loadPage() }
        .onChange(of: notebook?.pages.map(\.id)) { _, ids in
            guard let ids, !ids.isEmpty else { return }
            if pageIndex >= ids.count { pageIndex = ids.count - 1 }
            if editor?.page.id != ids[pageIndex] { loadPage() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { editor?.flush() }
        }
        .onDisappear {
            editor?.flush()
            session.dismiss(editor: editor)
        }
        .fileImporter(isPresented: Binding(get: { importMode != nil }, set: { if !$0 { importMode = nil } }),
                      allowedContentTypes: importMode?.types ?? [.pdf]) { result in
            handleImport(result)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { insertImage(data) }
                photoItem = nil
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Delete this page?", isPresented: $confirmDeletePage, titleVisibility: .visible) {
            Button("Delete Page", role: .destructive) { deleteCurrentPage() }
        }
    }

    // MARK: Page area

    private func pageArea(editor: PageEditorModel) -> some View {
        GeometryReader { geo in
            ZStack {
                PageCanvasRepresentable(editor: editor, tools: tools) { location in
                    summon(at: location)
                }
                .id(editor.page.id)
                .ignoresSafeArea(.container, edges: .bottom)
                .onAppear {
                    tools.onInkyDeselected = { [weak session] in session?.dismiss(editor: editor) }
                    editor.onAskInkyAboutSelection = { [weak session] in session?.summon(editor: editor) }
                    session.onAddPage = { paper in addPageForInky(paper) }
                    setInkyHome(editor, areaSize: geo.size)
                }
                .onChange(of: geo.size) { _, size in setInkyHome(editor, areaSize: size) }

                VStack {
                    if let toast = session.toast {
                        InkyToastView(toast: toast) { session.dismissToast() }
                            .padding(.top, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    pageIndicator
                        .padding(.bottom, 20)
                }
                .animation(.snappy, value: session.toast)

                if session.phase == .idle {
                    InkyFloatingButton(state: session.characterState(on: editor), isAway: editor.choreographer.isOnStage) { summon(at: nil) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, Self.floatingButtonInset)
                        .padding(.bottom, Self.floatingButtonInset)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    InkyAskCard(session: session, editor: editor)
                        .position(askCardPosition(in: geo.size))
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: session.phase)
            .onChange(of: session.phase) { _, phase in
                if phase == .idle { editor.canvasController?.restoreToolPicker() }
            }
        }
    }

    /// Near the squeeze/hover point if we have one, else bottom-right by the Inky button.
    private func askCardPosition(in size: CGSize) -> CGPoint {
        let halfWidth: CGFloat = 210, halfHeight: CGFloat = 55, margin: CGFloat = 20
        guard let anchor = session.anchor else {
            return CGPoint(x: size.width - halfWidth - margin, y: size.height - halfHeight - margin - 10)
        }
        let below = anchor.y + halfHeight + 30
        let y = below + halfHeight < size.height ? below : anchor.y - halfHeight - 30
        return CGPoint(
            x: min(max(anchor.x, halfWidth + margin), size.width - halfWidth - margin),
            y: min(max(y, halfHeight + margin), size.height - halfHeight - margin)
        )
    }

    private var pageIndicator: some View {
        let count = notebook?.pages.count ?? 0
        return HStack(spacing: 14) {
            Button { pageIndex -= 1 } label: { Image(systemName: "chevron.left") }
                .disabled(pageIndex == 0)
                .accessibilityIdentifier("page.previous")
            Text("\(pageIndex + 1) / \(count)")
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .accessibilityIdentifier("page.indicator")
            Button { pageIndex += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(pageIndex >= count - 1)
                .accessibilityIdentifier("page.next")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(0.7))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .opacity(count > 1 ? 1 : 0)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { showsPages.toggle() } label: { Image(systemName: "sidebar.left") }
                .accessibilityLabel("Pages")
                .accessibilityIdentifier("notebook.pages")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { editor?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .accessibilityLabel("Undo")
            Button { editor?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .accessibilityLabel("Redo")

            Menu {
                Menu("New Page", systemImage: "doc.badge.plus") {
                    ForEach(PaperStyle.allCases) { style in
                        Button(style.title) { addPage(.paper(style)) }
                            .accessibilityIdentifier("notebook.addPage.\(style.rawValue)")
                    }
                }
                Button("Import PDF", systemImage: "doc.richtext") { importMode = .pdf }
                    .accessibilityIdentifier("notebook.importPDF")
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photo", systemImage: "photo")
                }
                Button("Image from Files", systemImage: "folder") { importMode = .image }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add")
            .accessibilityIdentifier("notebook.add")

            if let editor {
                InkyLayerMenu(editor: editor)
            }

            Menu {
                Button("Delete Page", systemImage: "trash", role: .destructive) { confirmDeletePage = true }
                    .accessibilityIdentifier("notebook.deletePage")
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("notebook.more")
        }
    }

    // MARK: Actions

    static let floatingButtonInset: CGFloat = 24
    static let floatingButtonSize: CGFloat = 60

    /// After drawing, Inky hops back into the floating button (bottom-right of the page area).
    private func setInkyHome(_ editor: PageEditorModel, areaSize: CGSize) {
        let offset = Self.floatingButtonInset + Self.floatingButtonSize / 2
        let center = CGPoint(x: areaSize.width - offset, y: areaSize.height - offset)
        editor.choreographer.homeLocator = { [weak editor] in
            editor?.canvasController?.pagePoint(forViewPoint: center)
        }
    }

    private func summon(at location: CGPoint?) {
        guard let editor else { return }
        session.summon(editor: editor, anchor: location)
    }

    private func loadPage() {
        guard let notebook, !notebook.pages.isEmpty else { return }
        let index = min(max(pageIndex, 0), notebook.pages.count - 1)
        let page = notebook.pages[index]
        guard editor?.page.id != page.id else { return }
        editor?.flush()
        if session.phase == .composing { session.dismiss(editor: editor) }
        editor = PageEditorModel(notebookID: notebookID, page: page, store: app.store)
    }

    private func addPage(_ background: PageBackground) {
        app.store.addPage(to: notebookID, at: pageIndex + 1, background: background)
        pageIndex += 1
    }

    /// Inky's `addPage`: a fresh page after this one, shown right away so Inky can work there.
    private func addPageForInky(_ paper: AddPageAction.Paper) -> PageEditorModel? {
        guard let style = PaperStyle(rawValue: paper.rawValue) else { return nil }
        app.store.addPage(to: notebookID, at: pageIndex + 1, background: .paper(style))
        pageIndex += 1
        loadPage()
        return editor
    }

    private func deleteCurrentPage() {
        guard let editor else { return }
        let id = editor.page.id
        self.editor = nil
        app.store.deletePage(id, from: notebookID)
        pageIndex = min(pageIndex, (notebook?.pages.count ?? 1) - 1)
        loadPage()
    }

    private func handleImport(_ result: Result<URL, Error>) {
        let mode = importMode ?? .pdf
        switch result {
        case .success(let url):
            if mode == .pdf {
                do {
                    let (_, firstIndex) = try app.store.importPDF(from: url, into: notebookID)
                    pageIndex = firstIndex
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { insertImage(data) }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func insertImage(_ data: Data) {
        guard let editor else { return }
        do {
            let placed = try app.store.addImage(data, to: editor.page.id, in: notebookID)
            editor.imageInsertedExternally(placed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Toolbar menu for the Inky layer: show/hide, per-annotation visibility, clear.
struct InkyLayerMenu: View {
    @Bindable var editor: PageEditorModel
    @AppStorage(InkyFeedback.soundsKey) private var soundsEnabled = true

    var body: some View {
        Menu {
            Toggle("Show Inky Layer", systemImage: "sparkles", isOn: $editor.showsInkyLayer)
                .accessibilityIdentifier("inkyLayer.toggle")
            Toggle("Inky Sounds", systemImage: "speaker.wave.2", isOn: $soundsEnabled)
                .accessibilityIdentifier("inkyLayer.sounds")
            if !editor.annotations.isEmpty {
                Section("On this page") {
                    ForEach(editor.annotations) { annotation in
                        Button {
                            editor.setHidden(annotation.id, !annotation.isHidden)
                        } label: {
                            Label(Self.title(for: annotation), systemImage: annotation.isHidden ? "eye.slash" : "eye")
                        }
                    }
                }
                Button("Clear Inky Layer", systemImage: "trash", role: .destructive) { editor.clearAnnotations() }
            }
        } label: {
            Image(systemName: editor.showsInkyLayer ? "sparkles" : "sparkles.rectangle.stack")
        }
        .accessibilityLabel("Inky layer")
        .accessibilityIdentifier("notebook.inkyLayer")
    }

    static func title(for annotation: InkyAnnotation) -> String {
        switch annotation.action {
        case .highlight(let a): a.note.map { "Highlight · \($0)" } ?? "Highlight"
        case .circle: "Circle"
        case .star: "Star"
        case .label(let a): "Label · \(a.text)"
        case .fillText(let a): "Text · \(a.text)"
        case .insertMoleculeCard(let a): "Molecule · \(a.caption ?? a.smiles)"
        case .insertGraphCard(let a): "Graph · \(a.spec.title ?? "")"
        case .draw(let a): a.caption.map { "Drawing · \($0)" } ?? "Drawing"
        case .addPage, .openSidebar, .say: ""
        }
    }
}

/// Thumbnails of every page, tap to jump.
struct PageStrip: View {
    let notebook: Notebook
    @Binding var selection: Int
    let onAddPage: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, page in
                        Button { selection = index } label: {
                            VStack(spacing: 6) {
                                PageThumbnail(notebookID: notebook.id, page: page, pixelWidth: 240)
                                    .aspectRatio(page.width / page.height, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(index == selection ? Theme.accent : Theme.hairline, lineWidth: index == selection ? 2 : 0.5)
                                    )
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(index == selection ? Theme.accent : Theme.secondaryText)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityIdentifier("pageStrip.page.\(index + 1)")
                    }
                    Button { onAddPage(notebook.pages.count) } label: {
                        Image(systemName: "plus")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("pageStrip.add")
                }
                .padding(16)
            }
            .onAppear { proxy.scrollTo(selection) }
        }
        .frame(width: 150)
        .background(Theme.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 0.5) }
    }
}
