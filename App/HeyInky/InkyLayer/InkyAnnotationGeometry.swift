import UIKit

/// Where each annotation sits, in normalized page space (user offset applied).
/// Sizes that should look constant on paper (stars, label text) are defined in page points.
enum InkyAnnotationGeometry {
    static let labelFontSize: CGFloat = 15
    static let labelPadding = CGSize(width: 8, height: 4)
    static let starSize: CGFloat = 26
    static let circlePadding: CGFloat = 6
    static let minCardSize = CGSize(width: 320, height: 260)
    static let hitSlop: CGFloat = 10

    static func labelFont(scale: CGFloat = 1) -> UIFont {
        let base = UIFont.systemFont(ofSize: labelFontSize * scale, weight: .semibold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: labelFontSize * scale)
    }

    /// Text box for a label at one of its `InkyLayout.labelCandidates` (0 = default spot).
    static func labelTextRect(_ label: LabelAction, pageSize: CGSize, placement: Int = 0) -> NormRect {
        let candidates = InkyLayout.labelCandidates(label, pageSize: pageSize)
        return candidates[safe: placement] ?? candidates[0]
    }

    static func cardRect(near: NormRect, pageSize: CGSize) -> NormRect {
        let w = max(near.width, minCardSize.width / pageSize.width)
        let h = max(near.height, minCardSize.height / pageSize.height)
        let x = min(max(near.x, 0.01), max(0.01, 0.99 - w))
        let y = min(max(near.y, 0.01), max(0.01, 0.99 - h))
        return NormRect(x: x, y: y, width: min(w, 0.98), height: min(h, 0.98))
    }

    static func starRect(_ point: NormPoint, pageSize: CGSize) -> NormRect {
        let w = starSize / pageSize.width, h = starSize / pageSize.height
        return NormRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
    }

    static func circleRect(_ region: NormRect, pageSize: CGSize) -> NormRect {
        region.insetBy(dx: -circlePadding / pageSize.width, dy: -circlePadding / pageSize.height)
    }

    /// Visual bounds of an annotation, before the user offset.
    static func baseBounds(for action: InkyAction, pageSize: CGSize, labelPlacement: Int = 0) -> NormRect {
        switch action {
        case .highlight(let a): a.region
        case .circle(let a): circleRect(a.region, pageSize: pageSize)
        case .star(let a): starRect(a.point, pageSize: pageSize)
        case .label(let a): union(labelTextRect(a, pageSize: pageSize, placement: labelPlacement), NormRect(x: a.anchor.x, y: a.anchor.y, width: 0, height: 0))
        case .fillText(let a): a.region
        case .insertMoleculeCard(let a): cardRect(near: a.near, pageSize: pageSize)
        case .insertGraphCard(let a): cardRect(near: a.near, pageSize: pageSize)
        case .draw(let a): NormRect(DrawInk.layout(a, pageSize: pageSize).bounds, in: pageSize)
        // Figures are measured and placed when Inky adds them; `near` is their frame.
        case .insertChemScheme(let a): a.near
        case .insertDiagram(let a): a.near
        case .insertMath(let a): a.near
        case .insertPractice(let a): a.near
        case .annotateStructure, .annotateShape, .addPage, .openSidebar, .say: .zero
        }
    }

    static func bounds(for annotation: InkyAnnotation, pageSize: CGSize) -> NormRect {
        baseBounds(for: annotation.action, pageSize: pageSize, labelPlacement: annotation.labelPlacement ?? 0).offsetBy(dx: annotation.offset.x, dy: annotation.offset.y)
    }

    static func hitRect(for annotation: InkyAnnotation, pageSize: CGSize) -> NormRect {
        let b = bounds(for: annotation, pageSize: pageSize)
        return b.insetBy(dx: -hitSlop / pageSize.width, dy: -hitSlop / pageSize.height)
    }

    static func union(_ a: NormRect, _ b: NormRect) -> NormRect {
        let minX = min(a.minX, b.minX), minY = min(a.minY, b.minY)
        return NormRect(x: minX, y: minY, width: max(a.maxX, b.maxX) - minX, height: max(a.maxY, b.maxY) - minY)
    }
}

extension InkyAction {
    /// Molecule and graph cards (interactive) and Inky's figures: views rather than ink marks.
    var isCard: Bool {
        switch self {
        case .insertMoleculeCard, .insertGraphCard, .insertChemScheme, .insertDiagram, .insertMath, .insertPractice: true
        default: false
        }
    }
}

extension NormRect {
    func intersects(_ other: NormRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }
}
