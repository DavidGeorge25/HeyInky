import Foundation

/// A part of a picture on the page — a filled region (nucleus, mitochondrion, a lung lobe) or a
/// cluster of line marks (folded ER membranes) — found by `ImagePartFinder`. Inky labels parts by
/// id (`labelParts`); the app points exactly at them.
struct PagePart: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case region, marks }

    var id: String
    var kind: Kind
    /// Color name ("light green", "orange").
    var color: String
    /// "round", "oval", "elongated", "irregular" (regions) or "lines" (marks).
    var shape: String
    /// Normalized page coordinates.
    var box: NormRect
    /// A point well inside the part (or on one of its lines, for marks).
    var point: NormPoint
    /// Points around the part's outer edge (on its drawn outline when it has one).
    var outline: [NormPoint]
    /// Share of its picture's area, 0…1.
    var area: Double
    /// The part this one sits inside, if any.
    var inside: String?
    /// Drawn with a dark outline.
    var outlined: Bool
    /// Has markings inside (cristae, folds, texture).
    var detailed: Bool
    /// The picture it belongs to (normalized page frame).
    var picture: NormRect

    /// Nearest outline point to `p` (falls back to `point`).
    func edgePoint(toward p: NormPoint, aspect: Double = 1) -> NormPoint {
        outline.min { a, b in
            hypot((a.x - p.x) * aspect, a.y - p.y) < hypot((b.x - p.x) * aspect, b.y - p.y)
        } ?? point
    }
}
