import Foundation

/// A closed shape drawn on the page (in an image, ink or a PDF figure): a block, a ramp, a triangle,
/// a circle. Inky marks it by id (`annotateShape`) — forces, angle arcs, side labels — and the app
/// does the geometry.
struct PageShape: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case triangle, rectangle, square, quadrilateral, polygon, circle }

    /// Another shape this one rests on: one of our edges lies along one of theirs.
    struct Contact: Codable, Hashable, Sendable {
        var other: String
        /// Index into `vertices` of our edge's start (edge k runs from vertex k to k+1).
        var edge: Int
        /// The contact surface's angle from horizontal, degrees (0–90).
        var slope: Double
    }

    var id: String
    var kind: Kind
    /// Normalized page coordinates; edge k joins vertex k and k+1 (wrapping).
    var vertices: [NormPoint]
    var center: NormPoint
    /// Circles: radius in page points.
    var radius: Double
    /// Interior angle at each vertex, degrees.
    var angles: [Double]
    var contacts: [Contact]

    func vertexIndex(_ id: String) -> Int? {
        let digits = id.lowercased().drop { !$0.isNumber }
        guard let n = Int(digits), n >= 1, n <= vertices.count else { return nil }
        return n - 1
    }

    /// "e2" → 1, "v2-v3" → 1 (edge from v2 to v3, either direction).
    func edgeIndex(_ id: String) -> Int? {
        let parts = id.lowercased().split(whereSeparator: { $0 == "-" || $0 == "–" })
        if parts.count == 2, let a = vertexIndex(String(parts[0])), let b = vertexIndex(String(parts[1])) {
            let n = vertices.count
            if (a + 1) % n == b { return a }
            if (b + 1) % n == a { return b }
            return nil
        }
        guard id.lowercased().hasPrefix("e"), let k = vertexIndex(id) else { return nil }
        return k
    }
}
