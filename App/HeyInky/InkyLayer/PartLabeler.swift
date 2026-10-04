import CoreGraphics
import Foundation

/// Compiles `labelParts` into textbook labels: names in tidy columns beside the picture (or rows
/// above/below it when the sides have no room), ordered like their parts so leader lines don't
/// cross, each arrow ending exactly on its part (inside it, or on its outline for a membrane).
enum PartLabeler {
    struct Output {
        var labels: [LabelAction] = []
        var problems: [String] = []
    }

    enum Side: CaseIterable { case left, right, top, bottom }

    /// - Parameters:
    ///   - avoid: page content labels must not cover (text, ink, Inky's marks), normalized.
    ///   - labelSize: a label's text-box size in points.
    static func compile(_ action: LabelPartsAction, parts: [PagePart], pageSize: CGSize, avoid: [NormRect] = [],
                        labelSize: (String) -> CGSize) -> Output {
        var out = Output()
        let W = pageSize.width, H = pageSize.height
        let margin: CGFloat = 12, gap: CGFloat = 26, spacing: CGFloat = 7

        struct Item {
            var text: String
            var target: CGPoint
            var part: PagePart?
            var edge: Bool
            var size: CGSize
            var picture: NormRect?
            var side: Side = .left
            var rect: CGRect = .zero
        }
        func lookup(_ id: String) -> PagePart? {
            let key = id.trimmingCharacters(in: .whitespaces).uppercased()
            return parts.first { $0.id.uppercased() == key }
        }
        var items: [Item] = []
        for l in action.labels {
            let text = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let id = l.part, let part = lookup(id) {
                items.append(Item(text: text, target: part.point.cgPoint(in: pageSize), part: part, edge: l.edge && !part.outline.isEmpty,
                                  size: labelSize(text), picture: part.picture))
            } else if let x = l.x, let y = l.y {
                let p = NormPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
                let picture = parts.first { $0.picture.contains(p) }?.picture
                items.append(Item(text: text, target: p.cgPoint(in: pageSize), part: nil, edge: false, size: labelSize(text), picture: picture))
            } else {
                out.problems.append("\"\(text)\" has no part")
            }
        }
        guard !items.isEmpty else { return out }

        var blocked = avoid.map { $0.cgRect(in: pageSize) }
        // One layout per picture (labels for loose points share one too).
        let groups = Dictionary(grouping: items.indices) { items[$0].picture.map { "\($0.x),\($0.y),\($0.width)" } ?? "page" }
        for (_, members) in groups.sorted(by: { $0.key < $1.key }) {
            // The drawing's extent: its top-level parts (the picture's white margins don't count),
            // plus every target.
            var content = CGRect.null
            if let picture = items[members[0]].picture {
                for p in parts where p.picture == picture && p.inside == nil { content = content.union(p.box.cgRect(in: pageSize)) }
            }
            for i in members { content = content.union(CGRect(origin: items[i].target, size: .zero)) }
            if content.width < 40 || content.height < 40 { content = content.insetBy(dx: -30, dy: -30) }
            let center = CGPoint(x: content.midX, y: content.midY)

            // Room on each side of the drawing.
            func fits(_ side: Side, _ size: CGSize) -> Bool {
                switch side {
                case .left: content.minX - gap - size.width >= margin
                case .right: content.maxX + gap + size.width <= W - margin
                case .top: content.minY - gap - size.height >= margin
                case .bottom: content.maxY + gap + size.height <= H - margin
                }
            }
            var rowWidth: [Side: CGFloat] = [:]
            for i in members.sorted(by: { items[$0].target.y < items[$1].target.y }) {
                let t = items[i].target
                let rx = (t.x - center.x) / max(content.width, 1), ry = (t.y - center.y) / max(content.height, 1)
                let horizontal: Side = rx < 0 ? .left : .right, vertical: Side = ry < 0 ? .top : .bottom
                let opposite: Side = horizontal == .left ? .right : .left, otherVertical: Side = vertical == .top ? .bottom : .top
                // Columns read best; rows above/below when the target is clearly high or low.
                let order: [Side] = abs(ry) > abs(rx) * 1.6 ? [vertical, horizontal, otherVertical, opposite] : [horizontal, vertical, opposite, otherVertical]
                let size = items[i].size
                let side = order.first { side in
                    guard fits(side, size) else { return false }
                    if side == .top || side == .bottom {
                        return (rowWidth[side] ?? 0) + size.width + spacing <= W - 2 * margin
                    }
                    return true
                } ?? .bottom
                items[i].side = side
                if side == .top || side == .bottom { rowWidth[side, default: 0] += size.width + spacing }
            }

            for side in Side.allCases {
                var row = members.filter { items[$0].side == side }
                guard !row.isEmpty else { continue }
                let vertical = side == .left || side == .right
                // Along the side: as close to each target as possible, spaced so they don't touch.
                row.sort { vertical ? items[$0].target.y < items[$1].target.y : items[$0].target.x < items[$1].target.x }
                let extent = { (i: Int) in vertical ? items[i].size.height : items[i].size.width }
                var centers = row.map { vertical ? items[$0].target.y : items[$0].target.x }
                let lo = margin, hi = (vertical ? H : W) - margin
                for k in centers.indices {
                    let minC = k == 0 ? lo + extent(row[k]) / 2 : centers[k - 1] + extent(row[k - 1]) / 2 + spacing + extent(row[k]) / 2
                    centers[k] = max(centers[k], minC)
                }
                for k in centers.indices.reversed() {
                    let maxC = k == centers.count - 1 ? hi - extent(row[k]) / 2 : centers[k + 1] - extent(row[k + 1]) / 2 - spacing - extent(row[k]) / 2
                    centers[k] = min(centers[k], maxC)
                }
                func rect(_ i: Int, _ c: CGFloat) -> CGRect {
                    let s = items[i].size
                    switch side {
                    case .left: return CGRect(x: content.minX - gap - s.width, y: c - s.height / 2, width: s.width, height: s.height)
                    case .right: return CGRect(x: content.maxX + gap, y: c - s.height / 2, width: s.width, height: s.height)
                    case .top: return CGRect(x: c - s.width / 2, y: content.minY - gap - s.height, width: s.width, height: s.height)
                    case .bottom: return CGRect(x: c - s.width / 2, y: content.maxY + gap, width: s.width, height: s.height)
                    }
                }
                // Uncross: swap two labels' slots while their leaders cross.
                var slotOf = Array(row.indices)  // slotOf[k] = slot for row[k]
                func leader(_ k: Int) -> (CGPoint, CGPoint) {
                    let r = rect(row[k], centers[slotOf[k]])
                    let t = items[row[k]].target
                    return (CGPoint(x: min(max(t.x, r.minX), r.maxX), y: min(max(t.y, r.minY), r.maxY)), t)
                }
                for _ in 0..<40 {
                    var swapped = false
                    outer: for a in row.indices {
                        for b in row.indices where b > a {
                            let (p, q) = leader(a), (r, s) = leader(b)
                            if crosses(p, q, r, s) {
                                slotOf.swapAt(a, b)
                                swapped = true
                                break outer
                            }
                        }
                    }
                    if !swapped { break }
                }
                for k in row.indices {
                    var r = rect(row[k], centers[slotOf[k]])
                    // Off whatever is written there: step outward.
                    let outward: CGPoint = switch side {
                    case .left: CGPoint(x: -1, y: 0)
                    case .right: CGPoint(x: 1, y: 0)
                    case .top: CGPoint(x: 0, y: -1)
                    case .bottom: CGPoint(x: 0, y: 1)
                    }
                    var tries = 0
                    while blocked.contains(where: { $0.intersects(r.insetBy(dx: 1, dy: 1)) }) && tries < 8 {
                        let next = r.offsetBy(dx: outward.x * 10, dy: outward.y * 10)
                        guard next.minX >= 2, next.minY >= 2, next.maxX <= W - 2, next.maxY <= H - 2 else { break }
                        r = next
                        tries += 1
                    }
                    r.origin.x = min(max(r.minX, 4), W - 4 - r.width)
                    r.origin.y = min(max(r.minY, 4), H - 4 - r.height)
                    blocked.append(r)
                    items[row[k]].rect = r
                }
            }
        }

        for item in items {
            var target = item.target
            if item.edge, let part = item.part {
                let c = NormPoint(x: Double(item.rect.midX / W), y: Double(item.rect.midY / H))
                target = part.edgePoint(toward: c, aspect: Double(W / H)).cgPoint(in: pageSize)
            }
            out.labels.append(LabelAction(
                anchor: NormPoint(x: Double(target.x / W), y: Double(target.y / H)), text: item.text, arrow: true,
                textAt: NormPoint(x: Double(item.rect.minX / W), y: Double(item.rect.minY / H))
            ))
        }
        return out
    }

    static func crosses(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint, _ s: CGPoint) -> Bool {
        func d(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        return d(p, q, r) * d(p, q, s) < 0 && d(r, s, p) * d(r, s, q) < 0
    }
}
