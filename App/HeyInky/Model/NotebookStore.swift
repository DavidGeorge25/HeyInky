import Foundation
import Observation
import PDFKit
import PencilKit
import UIKit

/// File-based persistence:
///
///     <root>/<notebookID>/notebook.json          Notebook (metadata + page list)
///     <root>/<notebookID>/pages/<pageID>.drawing  PKDrawing.dataRepresentation()
///     <root>/<notebookID>/pages/<pageID>.inky.json [InkyAnnotation]
///     <root>/<notebookID>/assets/<name>           imported PDFs and images
///
/// All writes are atomic. See DECISIONS.md for why this beats SwiftData here.
@MainActor
@Observable
final class NotebookStore {
    let rootURL: URL
    private(set) var notebooks: [Notebook] = []
    /// Bumped whenever a page's rendered content changes, so thumbnails refresh.
    private(set) var contentVersion: [UUID: Int] = [:]
    var lastError: String?

    @ObservationIgnored private var pdfCache: [String: PDFDocument] = [:]
    @ObservationIgnored private var imageCache: [String: UIImage] = [:]

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static var defaultRootURL: URL {
        URL.documentsDirectory.appendingPathComponent("Notebooks", isDirectory: true)
    }

    init(rootURL: URL = NotebookStore.defaultRootURL) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    // MARK: Notebooks

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        notebooks = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("notebook.json")) else { return nil }
            return try? decoder.decode(Notebook.self, from: data)
        }
        sortNotebooks()
    }

    func notebook(id: UUID) -> Notebook? {
        notebooks.first { $0.id == id }
    }

    @discardableResult
    func createNotebook(title: String, paper: PaperStyle = .lined) -> Notebook {
        var notebook = Notebook(title: title, defaultPaper: paper)
        notebook.pages = [Page(background: .paper(paper))]
        save(notebook)
        return notebook
    }

    func save(_ notebook: Notebook) {
        var notebook = notebook
        notebook.modifiedAt = .now
        do {
            let dir = directory(for: notebook.id)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("pages"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
            try encoder.encode(notebook).write(to: dir.appendingPathComponent("notebook.json"), options: .atomic)
        } catch {
            lastError = "Couldn't save \(notebook.title): \(error.localizedDescription)"
        }
        if let index = notebooks.firstIndex(where: { $0.id == notebook.id }) {
            notebooks[index] = notebook
        } else {
            notebooks.append(notebook)
        }
        sortNotebooks()
    }

    func setInkyLayerHidden(_ hidden: Bool, in id: UUID) {
        guard var notebook = notebook(id: id), (notebook.inkyLayerHidden ?? false) != hidden else { return }
        notebook.inkyLayerHidden = hidden
        save(notebook)
    }

    func rename(_ id: UUID, to title: String) {
        guard var notebook = notebook(id: id) else { return }
        notebook.title = title
        save(notebook)
    }

    func deleteNotebook(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        notebooks.removeAll { $0.id == id }
    }

    // MARK: Pages

    @discardableResult
    func addPage(to notebookID: UUID, at index: Int? = nil, background: PageBackground? = nil) -> Page? {
        guard var notebook = notebook(id: notebookID) else { return nil }
        let size = notebook.pages.first(where: {
            if case .paper = $0.background { return true } else { return false }
        })?.size ?? Page.defaultSize
        let page = Page(size: size, background: background ?? .paper(notebook.defaultPaper))
        let insertAt = min(index ?? notebook.pages.count, notebook.pages.count)
        notebook.pages.insert(page, at: insertAt)
        save(notebook)
        return page
    }

    func deletePage(_ pageID: UUID, from notebookID: UUID) {
        guard var notebook = notebook(id: notebookID) else { return }
        notebook.pages.removeAll { $0.id == pageID }
        if notebook.pages.isEmpty {
            notebook.pages = [Page(background: .paper(notebook.defaultPaper))]
        }
        let pages = directory(for: notebookID).appendingPathComponent("pages")
        try? FileManager.default.removeItem(at: pages.appendingPathComponent("\(pageID).drawing"))
        try? FileManager.default.removeItem(at: pages.appendingPathComponent("\(pageID).inky.json"))
        save(notebook)
    }

    func updatePage(_ page: Page, in notebookID: UUID) {
        guard var notebook = notebook(id: notebookID),
              let index = notebook.pages.firstIndex(where: { $0.id == page.id }) else { return }
        notebook.pages[index] = page
        save(notebook)
        bumpVersion(page.id)
    }

    // MARK: Ink

    func drawing(for pageID: UUID, in notebookID: UUID) -> PKDrawing {
        guard let data = try? Data(contentsOf: drawingURL(pageID, notebookID)) else { return PKDrawing() }
        return (try? PKDrawing(data: data)) ?? PKDrawing()
    }

    func saveDrawing(_ drawing: PKDrawing, for pageID: UUID, in notebookID: UUID) {
        do {
            try drawing.dataRepresentation().write(to: drawingURL(pageID, notebookID), options: .atomic)
            touch(notebookID)
            bumpVersion(pageID)
        } catch {
            lastError = "Couldn't save ink: \(error.localizedDescription)"
        }
    }

    // MARK: Inky layer

    func annotations(for pageID: UUID, in notebookID: UUID) -> [InkyAnnotation] {
        guard let data = try? Data(contentsOf: annotationsURL(pageID, notebookID)) else { return [] }
        return (try? decoder.decode([InkyAnnotation].self, from: data)) ?? []
    }

    func saveAnnotations(_ annotations: [InkyAnnotation], for pageID: UUID, in notebookID: UUID) {
        do {
            try encoder.encode(annotations).write(to: annotationsURL(pageID, notebookID), options: .atomic)
            touch(notebookID)
        } catch {
            lastError = "Couldn't save Inky layer: \(error.localizedDescription)"
        }
    }

    // MARK: Assets

    func assetURL(_ name: String, in notebookID: UUID) -> URL {
        directory(for: notebookID).appendingPathComponent("assets").appendingPathComponent(name)
    }

    func pdfDocument(_ asset: String, in notebookID: UUID) -> PDFDocument? {
        let key = "\(notebookID)/\(asset)"
        if let cached = pdfCache[key] { return cached }
        let document = PDFDocument(url: assetURL(asset, in: notebookID))
        pdfCache[key] = document
        return document
    }

    func image(_ asset: String, in notebookID: UUID) -> UIImage? {
        let key = "\(notebookID)/\(asset)"
        if let cached = imageCache[key] { return cached }
        let image = UIImage(contentsOfFile: assetURL(asset, in: notebookID).path)
        imageCache[key] = image
        return image
    }

    /// Copies a PDF into the notebook (creating a new notebook when `notebookID` is nil) and
    /// appends one page per PDF page. Returns the notebook and the first new page's index.
    @discardableResult
    func importPDF(from url: URL, into notebookID: UUID? = nil, title: String? = nil) throws -> (Notebook, Int) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw StoreError.unreadablePDF
        }
        var notebook: Notebook
        if let notebookID, let existing = self.notebook(id: notebookID) {
            notebook = existing
        } else {
            notebook = Notebook(title: title ?? url.deletingPathExtension().lastPathComponent)
            save(notebook)
        }
        let asset = "\(UUID().uuidString).pdf"
        try FileManager.default.copyItem(at: url, to: assetURL(asset, in: notebook.id))

        let firstIndex = notebook.pages.count
        for index in 0..<document.pageCount {
            guard let pdfPage = document.page(at: index) else { continue }
            notebook.pages.append(Page(size: Self.displaySize(of: pdfPage), background: .pdf(asset: asset, pageIndex: index)))
        }
        save(notebook)
        return (self.notebook(id: notebook.id) ?? notebook, firstIndex)
    }

    /// Stores image data as an asset and places it on the page, centered, at a sensible size.
    @discardableResult
    func addImage(_ data: Data, to pageID: UUID, in notebookID: UUID, center: NormPoint = NormPoint(x: 0.5, y: 0.4)) throws -> PlacedImage {
        guard let image = UIImage(data: data),
              var notebook = notebook(id: notebookID),
              let index = notebook.pages.firstIndex(where: { $0.id == pageID })
        else { throw StoreError.unreadableImage }

        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.cgImage?.alphaInfo ?? .first)
        let asset = "\(UUID().uuidString).\(opaque ? "jpg" : "png")"
        let encoded = asset.hasSuffix("jpg") ? image.jpegData(compressionQuality: 0.9) : image.pngData()
        try (encoded ?? data).write(to: assetURL(asset, in: notebookID), options: .atomic)

        let page = notebook.pages[index]
        let maxW = 0.6, maxH = 0.45
        let aspect = (image.size.width / image.size.height) * (page.height / page.width)
        var w = maxW, h = maxW / aspect
        if h > maxH { h = maxH; w = maxH * aspect }
        let placed = PlacedImage(id: UUID(), asset: asset, frame: NormRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h).clamped)
        notebook.pages[index].images.append(placed)
        save(notebook)
        bumpVersion(pageID)
        return placed
    }

    // MARK: Helpers

    static func displaySize(of pdfPage: PDFPage) -> CGSize {
        let box = pdfPage.bounds(for: .cropBox)
        let rotated = pdfPage.rotation % 180 != 0
        return rotated ? CGSize(width: box.height, height: box.width) : box.size
    }

    func directory(for notebookID: UUID) -> URL {
        rootURL.appendingPathComponent(notebookID.uuidString, isDirectory: true)
    }

    private func drawingURL(_ pageID: UUID, _ notebookID: UUID) -> URL {
        directory(for: notebookID).appendingPathComponent("pages/\(pageID).drawing")
    }

    private func annotationsURL(_ pageID: UUID, _ notebookID: UUID) -> URL {
        directory(for: notebookID).appendingPathComponent("pages/\(pageID).inky.json")
    }

    private func touch(_ notebookID: UUID) {
        guard let index = notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        notebooks[index].modifiedAt = .now
        // Persist the new modified date without re-sorting churn on every stroke.
        try? encoder.encode(notebooks[index]).write(to: directory(for: notebookID).appendingPathComponent("notebook.json"), options: .atomic)
    }

    private func bumpVersion(_ pageID: UUID) {
        contentVersion[pageID, default: 0] += 1
    }

    private func sortNotebooks() {
        notebooks.sort { $0.modifiedAt > $1.modifiedAt }
    }

    enum StoreError: LocalizedError {
        case unreadablePDF, unreadableImage
        var errorDescription: String? {
            switch self {
            case .unreadablePDF: "That PDF couldn't be opened."
            case .unreadableImage: "That image couldn't be read."
            }
        }
    }
}
