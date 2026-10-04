import PencilKit
import UIKit

/// The student's pen strokes reduced to their corners, for Inky's context: a hexagon becomes
/// its six vertices, a bond line its two ends. Lets the model attach what it draws (hydrogens on
/// carbons, arrows to atoms) to where the ink really is instead of estimating from the image.
enum InkSkeleton {
    /// Simplification tolerance and the smallest stroke kept, in page points.
    static let tolerance: CGFloat = 4
    static let minExtent: CGFloat = 8
    static let maxPointsPerStroke = 24

    /// - Parameter handwriting: recognized text lines; strokes inside them are writing, not drawing.
    static func paths(in drawing: PKDrawing, pageSize: CGSize, handwriting: [NormRect], limit: Int = 80) -> [[NormPoint]] {
        var result: [[NormPoint]] = []
        for stroke in drawing.strokes {
            let bounds = stroke.renderBounds
            guard max(bounds.width, bounds.height) >= minExtent else { continue }
            let normalized = NormRect(bounds, in: pageSize)
            let isWriting = handwriting.contains { InkyLayout.overlap(normalized, $0.insetBy(dx: -0.005, dy: -0.005)) > 0.8 }
            guard !isWriting else { continue }
            let points = simplify(SelectionGeometry.samplePoints(stroke, spacing: 2), tolerance: tolerance)
            guard points.count >= 2, points.count <= maxPointsPerStroke else { continue }
            result.append(points.map { NormPoint(x: $0.x / pageSize.width, y: $0.y / pageSize.height) })
            if result.count >= limit { break }
        }
        return result
    }

    /// Ramer–Douglas–Peucker.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var maxDistance: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = distance(points[i], toSegment: first, last)
            if d > maxDistance { maxDistance = d; index = i }
        }
        guard maxDistance > tolerance else { return [first, last] }
        let left = simplify(Array(points[...index]), tolerance: tolerance)
        let right = simplify(Array(points[index...]), tolerance: tolerance)
        return left.dropLast() + right
    }

    private static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let lengthSquared = d.x * d.x + d.y * d.y
        // A closed loop (start == end): distance from the start point.
        guard lengthSquared > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / lengthSquared))
        return hypot(p.x - (a.x + t * d.x), p.y - (a.y + t * d.y))
    }
}
