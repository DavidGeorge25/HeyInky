import PencilKit
import SwiftUI
import UIKit

/// A notebook as a PDF: each page at its own size, the paper/PDF background as vectors, then
/// images, text, the student's ink and (optionally) Inky's marks.
@MainActor
enum NotebookExporter {
    static func pdf(notebook: Notebook, store: NotebookStore, includeInky: Bool = true) throws -> URL {
        let name = notebook.title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.isEmpty ? "Notebook" : name).pdf")
        let first = notebook.pages.first?.size ?? Page.defaultSize
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first))
        try renderer.writePDF(to: url) { ctx in
            for page in notebook.pages {
                let rect = CGRect(origin: .zero, size: page.size)
                ctx.beginPage(withBounds: rect, pageInfo: [:])
                PageRenderer.drawBackground(page: page, notebookID: notebook.id, store: store, in: rect, context: ctx.cgContext)
                let drawing = store.drawing(for: page.id, in: notebook.id)
                if !drawing.strokes.isEmpty {
                    var ink = UIImage()
                    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                        ink = drawing.image(from: rect, scale: 3)
                    }
                    ink.draw(in: rect)
                }
                if includeInky {
                    let annotations = store.annotations(for: page.id, in: notebook.id).filter { !$0.isHidden && $0.action.isPageAnnotation }
                    if !annotations.isEmpty, let marks = inkyLayerImage(annotations, pageSize: page.size) {
                        marks.draw(in: rect)
                    }
                }
            }
        }
        return url
    }

    /// Inky's marks rendered the way the layer shows them (cards use their native drawing).
    static func inkyLayerImage(_ annotations: [InkyAnnotation], pageSize: CGSize) -> UIImage? {
        let view = ZStack(alignment: .topLeading) {
            ForEach(annotations) { annotation in
                let rect = InkyAnnotationGeometry.bounds(for: annotation, pageSize: pageSize).cgRect(in: pageSize)
                InkyAnnotationView(annotation: annotation, pageSize: pageSize, scale: 1)
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = false
        return renderer.uiImage
    }
}

/// Share sheet for an exported file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
