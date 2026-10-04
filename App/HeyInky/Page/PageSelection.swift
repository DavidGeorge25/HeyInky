import PencilKit
import UIKit

/// What the Select tool has picked on a page: ink strokes (indices into the drawing), placed
/// images and Inky annotations. `bounds` is their union in normalized page space.
struct PageSelection: Equatable {
    var strokeIndices: [Int] = []
    var imageIDs: Set<UUID> = []
    var annotationIDs: Set<UUID> = []
    var textBoxIDs: Set<UUID> = []
    var bounds: NormRect = .zero

    var isEmpty: Bool { strokeIndices.isEmpty && imageIDs.isEmpty && annotationIDs.isEmpty && textBoxIDs.isEmpty }
}

/// Everything on a page that an undoable whole-page edit (move, scale, paste, delete) touches.
struct PageContentSnapshot {
    var drawing: PKDrawing
    var images: [PlacedImage]
    var annotations: [InkyAnnotation]
    var textBoxes: [PageTextBox] = []
}

/// Copy/paste between pages and notebooks (in memory, for this app session).
@MainActor
enum PageClipboard {
    struct Content {
        /// Page points on the page they were copied from.
        var strokes: [PKStroke]
        var images: [(data: Data, frame: NormRect)]
        /// Offsets baked in.
        var annotations: [InkyAnnotation]
        var textBoxes: [PageTextBox] = []
        var bounds: NormRect
        var sourcePageSize: CGSize
    }

    static var content: Content?

    static var hasContent: Bool { content != nil || UIPasteboard.general.hasImages }
}

enum SelectionGeometry {
    /// Even-odd point-in-polygon.
    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Points along a stroke (transform applied), in page points.
    static func samplePoints(_ stroke: PKStroke, spacing: CGFloat = 6) -> [CGPoint] {
        let points = stroke.path.interpolatedPoints(by: .distance(spacing)).map { $0.location.applying(stroke.transform) }
        return points.isEmpty ? [stroke.renderBounds.center] : points
    }

    /// `p` scaled by `scale` about `anchor`, then moved by `delta` (any consistent units).
    static func transform(_ p: CGPoint, anchor: CGPoint, scale: CGFloat, delta: CGPoint) -> CGPoint {
        CGPoint(x: anchor.x + (p.x - anchor.x) * scale + delta.x, y: anchor.y + (p.y - anchor.y) * scale + delta.y)
    }

    static func transform(_ r: NormRect, anchor: CGPoint, scale: CGFloat, delta: CGPoint) -> NormRect {
        let origin = transform(CGPoint(x: r.x, y: r.y), anchor: anchor, scale: scale, delta: delta)
        return NormRect(x: origin.x, y: origin.y, width: r.width * scale, height: r.height * scale)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension InkyAction {
    /// The action moved/scaled in normalized page space (text and marker sizes stay the same).
    func transformed(anchor: CGPoint, scale: CGFloat, delta: CGPoint) -> InkyAction {
        func point(_ p: NormPoint) -> NormPoint {
            let t = SelectionGeometry.transform(CGPoint(x: p.x, y: p.y), anchor: anchor, scale: scale, delta: delta)
            return NormPoint(x: t.x, y: t.y)
        }
        func rect(_ r: NormRect) -> NormRect { SelectionGeometry.transform(r, anchor: anchor, scale: scale, delta: delta) }
        switch self {
        case .highlight(var a): a.region = rect(a.region); return .highlight(a)
        case .circle(var a): a.region = rect(a.region); return .circle(a)
        case .star(var a): a.point = point(a.point); return .star(a)
        case .label(var a): a.anchor = point(a.anchor); return .label(a)
        case .fillText(var a): a.region = rect(a.region); return .fillText(a)
        case .insertMoleculeCard(var a): a.near = rect(a.near); return .insertMoleculeCard(a)
        case .insertGraphCard(var a): a.near = rect(a.near); return .insertGraphCard(a)
        case .draw(var a):
            // Shapes and line positions scale; pen width and handwriting size stay true to paper.
            for i in a.shapes.indices { a.shapes[i].points = a.shapes[i].points.map(point) }
            return .draw(a)
        case .insertChemScheme(var a): a.near = rect(a.near); return .insertChemScheme(a)
        case .insertDiagram(var a): a.near = rect(a.near); return .insertDiagram(a)
        case .insertMath(var a): a.near = rect(a.near); return .insertMath(a)
        case .insertPractice(var a): a.near = rect(a.near); return .insertPractice(a)
        case .annotateStructure, .annotateShape, .addPage, .openSidebar, .say: return self
        }
    }
}

extension InkyAnnotation {
    /// The user's offset folded into the action's coordinates.
    var bakingOffset: InkyAnnotation {
        guard offset.x != 0 || offset.y != 0 else { return self }
        var copy = self
        copy.action = action.transformed(anchor: .zero, scale: 1, delta: CGPoint(x: offset.x, y: offset.y))
        copy.offset = NormPoint(x: 0, y: 0)
        return copy
    }
}
