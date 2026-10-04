import UIKit

/// Keeps Inky's text readable: picks where each label's text box and each highlight's note tag
/// go so they don't cover each other, the things Inky marked, or what's written on the page.
///
/// Every label / noted highlight has a list of candidate spots around its target. When Inky adds
/// one, `bestPlacement` scores the candidates against everything already there and the page's
/// content, and the winner's index is stored on the annotation (`InkyAnnotation.labelPlacement`),
/// so marks never jump around afterwards. Index 0 is the classic default spot.
enum InkyLayout {
    // MARK: Candidates

    /// Text-box candidates for a label, nearest first. 0–3 are the original four
    /// (default side, flipped horizontally, flipped vertically, both).
    static func labelCandidates(_ label: LabelAction, pageSize: CGSize) -> [NormRect] {
        let size = labelTextSize(label, pageSize: pageSize)
        let w = size.width, h = size.height
        let a = label.anchor
        if let t = label.textAt { return [rect(t.x, t.y, w, h)] }
        guard label.arrow else {
            // Beside the point (no arrow): right, left, then shifted down/up.
            let gap = 8 / pageSize.width
            let right = a.x + gap, left = a.x - gap - w
            let mid = a.y - h / 2
            let primaryRight = right + w <= 0.98
            let (first, second) = primaryRight ? (right, left) : (left, right)
            return [
                rect(first, mid, w, h), rect(second, mid, w, h),
                rect(first, mid + h * 1.15, w, h), rect(second, mid + h * 1.15, w, h),
                rect(first, mid - h * 1.15, w, h), rect(second, mid - h * 1.15, w, h),
            ]
        }
        var result: [NormRect] = []
        for distance in [1.0, 1.9, 2.8] {
            let gapX = 36 * distance / pageSize.width, gapY = 28 * distance / pageSize.height
            let right = a.x + gapX, left = a.x - gapX - w
            let above = a.y - gapY - h, below = a.y + gapY
            let preferRight = right + w <= 0.98, preferAbove = above >= 0.02
            for flip in 0..<4 {
                let onRight = (flip & 1 == 0) == preferRight
                let onTop = (flip & 2 == 0) == preferAbove
                result.append(rect(onRight ? right : left, onTop ? above : below, w, h))
            }
            // Straight out to the side, level with the anchor.
            result.append(rect(preferRight ? right : left, a.y - h / 2, w, h))
            result.append(rect(preferRight ? left : right, a.y - h / 2, w, h))
        }
        return result
    }

    /// Note-tag candidates for a highlight: above the right end (the default), above the left
    /// end, below either end, then beside it.
    static func noteCandidates(_ highlight: HighlightAction, pageSize: CGSize) -> [NormRect] {
        guard let note = highlight.note, !note.isEmpty else { return [] }
        let size = noteSize(note, pageSize: pageSize)
        let w = size.width, h = size.height
        let r = highlight.region
        let lift = 4 / pageSize.height, side = 6 / pageSize.width
        return [
            rect(r.maxX - w, r.y - h - lift, w, h),
            rect(r.x, r.y - h - lift, w, h),
            rect(r.maxX - w, r.maxY + lift, w, h),
            rect(r.x, r.maxY + lift, w, h),
            rect(r.maxX + side, r.y + (r.height - h) / 2, w, h),
            rect(r.x - side - w, r.y + (r.height - h) / 2, w, h),
            rect(r.maxX - w, r.y - 2 * h - 2 * lift, w, h),
            rect(r.x, r.maxY + h + 2 * lift, w, h),
        ]
    }

    /// Where an annotation's text sits (label box or highlight note), user offset applied.
    static func textRect(for annotation: InkyAnnotation, pageSize: CGSize) -> NormRect? {
        let placement = annotation.labelPlacement ?? 0
        let rect: NormRect?
        switch annotation.action {
        case .label(let l): rect = labelCandidates(l, pageSize: pageSize)[safe: placement] ?? labelCandidates(l, pageSize: pageSize).first
        case .highlight(let h): rect = noteCandidates(h, pageSize: pageSize)[safe: placement] ?? noteCandidates(h, pageSize: pageSize).first
        default: rect = nil
        }
        return rect?.offsetBy(dx: annotation.offset.x, dy: annotation.offset.y)
    }

    // MARK: Choosing

    /// The cheapest candidate for a new label / noted highlight; nil = default (or nothing to place).
    /// - Parameter content: what's written or drawn on the page (text lines, ink), normalized.
    static func bestPlacement(for action: InkyAction, among existing: [InkyAnnotation], content: [NormRect], pageSize: CGSize) -> Int? {
        let candidates: [NormRect]
        var ownTarget: NormRect?
        switch action {
        case .label(let l):
            candidates = labelCandidates(l, pageSize: pageSize)
            let pad = 6.0 / pageSize.width
            ownTarget = NormRect(x: l.anchor.x - pad, y: l.anchor.y - pad, width: 2 * pad, height: 2 * pad)
        case .highlight(let h):
            candidates = noteCandidates(h, pageSize: pageSize)
            ownTarget = h.region
        default:
            return nil
        }
        guard !candidates.isEmpty else { return nil }

        let texts = existing.compactMap { textRect(for: $0, pageSize: pageSize) }
        let marked: [NormRect] = existing.compactMap { a in
            switch a.action {
            case .highlight, .circle, .star, .fillText, .insertMoleculeCard, .insertGraphCard:
                return InkyAnnotationGeometry.bounds(for: a, pageSize: pageSize)
            default:
                return nil
            }
        }
        func cost(_ r: NormRect) -> Double {
            var c = 0.0
            for t in texts { c += 12 * overlap(r, t) }
            for m in marked { c += 3 * overlap(r, m) }
            for t in content { c += 2 * overlap(r, t) }
            if let ownTarget { c += 4 * overlap(r, ownTarget) }
            // Clamped onto the page edge = shifted away from where it belongs.
            if r.x < 0.01 || r.y < 0.01 || r.maxX > 0.99 || r.maxY > 0.99 { c += 0.5 }
            return c
        }
        var best = 0, bestCost = Double.infinity
        for (i, r) in candidates.enumerated() {
            // Nearer spots win ties (a label far from its arrow tip reads worse).
            let c = cost(r) + Double(i) * 0.02
            if c < bestCost { best = i; bestCost = c }
        }
        return best == 0 ? nil : best
    }

    /// Inky's writing in a new drawing, moved off text Inky already put on the page (fill-ins,
    /// labels, notes, earlier drawings). Lines of working shift down/up a line at a time; atom
    /// labels are left alone (they belong where their bond is).
    static func placingDrawText(_ action: DrawAction, among existing: [InkyAnnotation], pageSize: CGSize) -> DrawAction {
        var obstacles: [CGRect] = existing.flatMap { annotation -> [CGRect] in
            switch annotation.action {
            case .fillText(let a): return [a.region.offsetBy(dx: annotation.offset.x, dy: annotation.offset.y).cgRect(in: pageSize)]
            case .draw(let d):
                let shift = CGPoint(x: annotation.offset.x * pageSize.width, y: annotation.offset.y * pageSize.height)
                return DrawInk.layout(d, pageSize: pageSize).segments.compactMap { $0.text?.rect.offsetBy(dx: shift.x, dy: shift.y) }
            default:
                return textRect(for: annotation, pageSize: pageSize).map { [$0.cgRect(in: pageSize)] } ?? []
            }
        }
        guard !obstacles.isEmpty else { return action }
        var result = action
        let placed = DrawInk.placeTexts(action, pageSize: pageSize).texts
        for index in placed.keys.sorted() {
            guard let item = placed[index], !DrawInk.isShortLabel(item.string) else { continue }
            let moved = DrawInk.resolve(item.rect, against: obstacles, direction: nil, isShort: false, pageSize: pageSize)
            if moved != item.rect {
                let dx = (moved.minX - item.rect.minX) / pageSize.width, dy = (moved.minY - item.rect.minY) / pageSize.height
                result.shapes[index].points = result.shapes[index].points.map { NormPoint(x: $0.x + dx, y: $0.y + dy) }
            }
            obstacles.append(moved)
        }
        return result
    }

    /// Fraction of `a` covered by `b`.
    static func overlap(_ a: NormRect, _ b: NormRect) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard w > 0, h > 0, a.width > 0, a.height > 0 else { return 0 }
        return (w * h) / (a.width * a.height)
    }

    // MARK: Sizes

    static let noteFontSize: CGFloat = 11
    static let notePadding = CGSize(width: 6, height: 2)

    static func noteFont(scale: CGFloat = 1) -> UIFont {
        let base = UIFont.systemFont(ofSize: noteFontSize * scale, weight: .semibold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: noteFontSize * scale)
    }

    static func noteSize(_ note: String, pageSize: CGSize) -> CGSize {
        let size = (note as NSString).size(withAttributes: [.font: noteFont()])
        return CGSize(width: (size.width.rounded(.up) + 4 + 2 * notePadding.width) / pageSize.width,
                      height: (size.height.rounded(.up) + 2 * notePadding.height) / pageSize.height)
    }

    static func labelTextSize(_ label: LabelAction, pageSize: CGSize) -> CGSize {
        let maxWidth = min(240, pageSize.width * 0.4)
        let size = (label.text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: InkyAnnotationGeometry.labelFont()], context: nil
        ).size
        // A little slack: SwiftUI's text can run a hair wider than NSString measures it.
        return CGSize(width: (size.width.rounded(.up) + 4 + 2 * InkyAnnotationGeometry.labelPadding.width) / pageSize.width,
                      height: (size.height.rounded(.up) + 2 * InkyAnnotationGeometry.labelPadding.height) / pageSize.height)
    }

    /// Kept on the page.
    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormRect {
        NormRect(x: min(max(x, 0.01), 0.99 - w), y: min(max(y, 0.01), 0.99 - h), width: w, height: h)
    }
}
