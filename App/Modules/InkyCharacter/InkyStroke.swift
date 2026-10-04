import CoreGraphics
import Foundation
import UIKit

/// How Inky draws one annotation: where its nib travels (in page points) and for how long.
/// The renderers reveal the annotation with the same progress, so ink appears under the nib.
struct InkyStroke: Equatable, Sendable {
    enum Kind: String, Sendable {
        case highlight, circle, star, label, fillText, card, draw
    }

    let annotationID: UUID
    let kind: Kind
    /// Annotation bounds in page points (user offset applied).
    let bounds: CGRect
    /// Seconds at normal speed.
    let duration: TimeInterval
    private let label: LabelGeometry?
    private let seed: Int
    /// Fraction of the bounds' width covered by fill text.
    private let textWidthFraction: CGFloat
    /// Inky's own drawing: the pen paths the nib follows, and the user offset (page points).
    private let drawLayout: DrawInk.Layout?
    private let drawOffset: CGPoint

    struct LabelGeometry: Equatable, Sendable {
        var textRect: CGRect
        var anchor: CGPoint
        var arrow: Bool
    }

    /// For labels with an arrow, the share of the stroke spent writing the text (the rest draws the arrow).
    static let labelTextShare: CGFloat = 0.6

    init?(annotation: InkyAnnotation, pageSize: CGSize) {
        let normalized = InkyAnnotationGeometry.bounds(for: annotation, pageSize: pageSize)
        let bounds = normalized.cgRect(in: pageSize)
        let offset = CGPoint(x: annotation.offset.x * pageSize.width, y: annotation.offset.y * pageSize.height)
        var label: LabelGeometry?
        var textWidthFraction: CGFloat = 1
        var drawLayout: DrawInk.Layout?
        let kind: Kind
        let duration: TimeInterval
        switch annotation.action {
        case .highlight:
            kind = .highlight
            duration = 0.45 + 0.3 * min(1, bounds.width / 400)
        case .circle:
            kind = .circle
            duration = 0.8
        case .star:
            kind = .star
            duration = 0.5
        case .label(let a):
            kind = .label
            let text = InkyAnnotationGeometry.labelTextRect(a, pageSize: pageSize, placement: annotation.labelPlacement ?? 0).cgRect(in: pageSize).offsetBy(dx: offset.x, dy: offset.y)
            let anchor = a.anchor.cgPoint(in: pageSize)
            label = LabelGeometry(textRect: text, anchor: CGPoint(x: anchor.x + offset.x, y: anchor.y + offset.y), arrow: a.arrow)
            duration = min(1.0, 0.35 + 0.025 * Double(a.text.count)) + (a.arrow ? 0.35 : 0)
        case .fillText(let a):
            kind = .fillText
            textWidthFraction = FillTextMark.textWidthFraction(a, size: bounds.size, scale: 1)
            duration = min(1.4, max(0.5, 0.3 + 0.05 * Double(a.text.count)))
        case .insertMoleculeCard, .insertGraphCard, .insertChemScheme, .insertDiagram, .insertMath, .insertPractice:
            kind = .card
            duration = 0.45
        case .draw(let a):
            kind = .draw
            let layout = DrawInk.layout(a, pageSize: pageSize, seed: CircleMark.seed(for: annotation.id))
            drawLayout = layout
            // A brisk but readable hand: ~420 pt of ink per second, a beat per stroke, capped.
            duration = min(7, 0.3 + Double(layout.totalLength) / 420 + 0.06 * Double(layout.segments.count))
        case .annotateStructure, .annotateShape, .addPage, .openSidebar, .say:
            return nil
        }
        self.annotationID = annotation.id
        self.kind = kind
        self.bounds = bounds
        self.duration = duration
        self.label = label
        self.seed = CircleMark.seed(for: annotation.id)
        self.textWidthFraction = textWidthFraction
        self.drawLayout = drawLayout
        self.drawOffset = offset
    }

    var start: CGPoint { tip(at: 0) }
    var end: CGPoint { tip(at: 1) }

    /// Nib position at `progress` (0…1), in page points.
    func tip(at progress: CGFloat) -> CGPoint {
        let p = min(max(progress, 0), 1)
        let b = bounds
        switch kind {
        case .highlight:
            // One marker swipe along the middle, with a little hand wobble.
            let x = b.minX + 3 + (b.width - 6) * p
            return CGPoint(x: x, y: b.midY + sin(p * 9 * .pi) * min(2, b.height * 0.08))
        case .circle:
            return HandDrawnLoop.point(at: p, in: b, seed: seed)
        case .star:
            return StarShape.outlinePoint(at: p, in: b)
        case .fillText:
            let width = b.width * textWidthFraction
            return CGPoint(x: b.minX + 2 + max(0, width - 4) * p, y: b.maxY - b.height * 0.22 + sin(p * 14 * .pi) * 1.5)
        case .label:
            guard let label else { return CGPoint(x: b.midX, y: b.midY) }
            let text = label.textRect
            let share = label.arrow ? Self.labelTextShare : 1
            if p <= share {
                let u = p / share
                return CGPoint(x: text.minX + 6 + (text.width - 12) * u, y: text.maxY - 4 + sin(u * 12 * .pi) * 1.2)
            }
            let u = (p - share) / (1 - share)
            let from = LabelMark.edgePoint(of: text, toward: label.anchor)
            return ArrowShape.point(at: u, from: from, to: label.anchor)
        case .card:
            return CGPoint(x: b.midX, y: b.maxY)
        case .draw:
            guard let drawLayout else { return CGPoint(x: b.midX, y: b.midY) }
            let nib = DrawInk.nib(drawLayout, at: p)
            return CGPoint(x: nib.x + drawOffset.x, y: nib.y + drawOffset.y)
        }
    }
}
