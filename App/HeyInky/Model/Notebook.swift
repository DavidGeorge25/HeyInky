import Foundation
import CoreGraphics

/// A notebook as stored in `<root>/<id>/notebook.json`. Ink and Inky annotations are
/// stored per page in separate files (see `NotebookStore`).
struct Notebook: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var pages: [Page]
    /// Paper used for new pages.
    var defaultPaper: PaperStyle
    /// The whole Inky layer is hidden (toolbar menu). Optional so older notebook.json files decode.
    var inkyLayerHidden: Bool?

    init(id: UUID = UUID(), title: String, pages: [Page] = [], defaultPaper: PaperStyle = .lined, now: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = now
        self.modifiedAt = now
        self.pages = pages
        self.defaultPaper = defaultPaper
    }
}

struct Page: Codable, Identifiable, Hashable, Sendable {
    /// US Letter at 96 dpi; a comfortable writing size on iPad.
    static let defaultSize = CGSize(width: 816, height: 1056)

    var id: UUID
    /// Page size in points. Ink (PKDrawing) coordinates use this space.
    var width: Double
    var height: Double
    var background: PageBackground
    var images: [PlacedImage]

    var size: CGSize { CGSize(width: width, height: height) }

    init(id: UUID = UUID(), size: CGSize = Page.defaultSize, background: PageBackground, images: [PlacedImage] = []) {
        self.id = id
        self.width = size.width
        self.height = size.height
        self.background = background
        self.images = images
    }
}

enum PaperStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case blank, lined, grid, dotted
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum PageBackground: Codable, Hashable, Sendable {
    case paper(PaperStyle)
    /// A page of an imported PDF stored in the notebook's assets folder.
    case pdf(asset: String, pageIndex: Int)
}

/// An image placed on the page, below the ink. Frame is normalized page space.
struct PlacedImage: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var asset: String
    var frame: NormRect
}

/// An Inky action living on a page's Inky layer, plus the user's edits to it.
struct InkyAnnotation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var action: InkyAction
    /// User move, in normalized page units.
    var offset: NormPoint
    var isHidden: Bool
    var createdAt: Date
    /// The question that produced it, for context in the layer list.
    var question: String?
    /// Labels only: which side of the anchor the text sits on (`InkyAnnotationGeometry.labelPlacements`),
    /// picked so labels don't cover each other. nil = default.
    var labelPlacement: Int?

    init(id: UUID = UUID(), action: InkyAction, offset: NormPoint = NormPoint(x: 0, y: 0), isHidden: Bool = false, createdAt: Date = .now, question: String? = nil) {
        self.id = id
        self.action = action
        self.offset = offset
        self.isHidden = isHidden
        self.createdAt = createdAt
        self.question = question
    }
}
