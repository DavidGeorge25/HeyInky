import SwiftUI
import UniformTypeIdentifiers

/// Notebook library: a calm grid of covers.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [UUID] = []
    @State private var showingPDFImporter = false
    @State private var renaming: Notebook?
    @State private var renameText = ""
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 32)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if app.store.notebooks.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 36) {
                        ForEach(app.store.notebooks) { notebook in
                            NavigationLink(value: notebook.id) {
                                NotebookCover(notebook: notebook)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.notebook.\(notebook.title)")
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") {
                                    renameText = notebook.title
                                    renaming = notebook
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    app.store.deleteNotebook(notebook.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                }
            }
            .background(Theme.canvasBackground.ignoresSafeArea())
            .navigationTitle("Notebooks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Menu("New Notebook", systemImage: "book.closed") {
                            ForEach(PaperStyle.allCases) { style in
                                Button(style.title) { createNotebook(paper: style) }
                                    .accessibilityIdentifier("library.new.\(style.rawValue)")
                            }
                        }
                        Button("Import PDF", systemImage: "doc.richtext") { showingPDFImporter = true }
                            .accessibilityIdentifier("library.importPDF")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                    .accessibilityIdentifier("library.add")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                NotebookView(notebookID: id, client: app.client)
            }
            .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    do {
                        let (notebook, _) = try app.store.importPDF(from: url)
                        path.append(notebook.id)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Rename Notebook", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let notebook = renaming { app.store.rename(notebook.id, to: renameText) }
                    renaming = nil
                }
            }
            .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            InkyCharacterView(state: .happy, size: 64)
            Text("A quiet place for your notes.")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Button("New Notebook") { createNotebook(paper: .lined) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("library.empty.new")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 160)
    }

    private func createNotebook(paper: PaperStyle) {
        let notebook = app.store.createNotebook(title: "Untitled", paper: paper)
        path.append(notebook.id)
    }
}

struct NotebookCover: View {
    @Environment(AppModel.self) private var app
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let page = notebook.pages.first {
                    PageThumbnail(notebookID: notebook.id, page: page)
                } else {
                    Color.white
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white)
                    .shadow(color: Theme.shadowColor, radius: 10, y: 4)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(notebook.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text("\(notebook.pages.count) page\(notebook.pages.count == 1 ? "" : "s") · \(notebook.modifiedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

/// Small render of a page (background + ink). Refreshes when the page's content changes.
struct PageThumbnail: View {
    @Environment(AppModel.self) private var app
    let notebookID: UUID
    let page: Page
    var pixelWidth: CGFloat = 360
    @State private var image: UIImage?

    var body: some View {
        let version = app.store.contentVersion[page.id, default: 0]
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: "\(page.id)-\(version)-\(page.images.count)") {
            image = PageRenderer.image(
                page: page, notebookID: notebookID, store: app.store,
                drawing: app.store.drawing(for: page.id, in: notebookID), pixelWidth: pixelWidth
            )
        }
    }
}
