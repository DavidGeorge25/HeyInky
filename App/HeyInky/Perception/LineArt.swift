import CoreGraphics
import Foundation

/// A binary ink bitmap (1 = ink) of line art: a placed image, the student's pen strokes, or a
/// PDF figure rendered to pixels. The perception pipeline is raster-only so photos, scans,
/// PDFs and Apple Pencil ink all go through the same steps:
///
///     threshold → thin to a 1-px skeleton → trace into paths → clean → simplify (polylines)
///
/// Coordinates are bitmap pixels (origin top-left).
struct InkBitmap: Sendable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? [UInt8](repeating: 0, count: width * height)
    }

    @inline(__always) subscript(x: Int, y: Int) -> Bool {
        get { x >= 0 && y >= 0 && x < width && y < height && pixels[y * width + x] != 0 }
        set { pixels[y * width + x] = newValue ? 1 : 0 }
    }

    var inkCount: Int { pixels.reduce(0) { $0 + Int($1) } }

    /// Dark marks on a light background. Light paper lines/grids and soft colors drop out; a local
    /// background estimate keeps shadowed photos working. `exclude` rects (normalized 0–1 within
    /// the image) are blanked, e.g. lines of prose that aren't part of a drawing.
    /// - Returns: the bitmap and the factor from image pixels to bitmap pixels.
    static func threshold(_ image: CGImage, maxSide: Int = 1000, exclude: [NormRect] = []) -> (InkBitmap, CGFloat)? {
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int((CGFloat(image.width) * scale).rounded())), h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard w >= 8, h >= 8 else { return nil }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var lum = [Float](repeating: 1, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4]), g = Float(rgba[i * 4 + 1]), b = Float(rgba[i * 4 + 2])
            lum[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        // Box mean via an integral image.
        var integral = [Float](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Float = 0
            for x in 0..<w {
                row += lum[y * w + x]
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        let r = max(8, min(w, h) / 12)
        var bits = InkBitmap(width: w, height: h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let v = lum[y * w + x]
                // Thin anti-aliased pen lines are mid-gray; light paper grids stay above 0.8.
                guard v < 0.72 else { continue }
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                let mean = sum / Float((x1 - x0) * (y1 - y0))
                if v < mean - 0.14 { bits.pixels[y * w + x] = 1 }
            }
        }
        for r in exclude {
            bits.clear(CGRect(x: r.x * Double(w) - 2, y: r.y * Double(h) - 2, width: r.width * Double(w) + 4, height: r.height * Double(h) + 4))
        }
        bits.removeSpecks(minPixels: 6)
        return (bits, scale)
    }

    mutating func clear(_ rect: CGRect) {
        let x0 = max(0, Int(rect.minX.rounded(.down))), x1 = min(width, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY.rounded(.down))), y1 = min(height, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return }
        for y in y0..<y1 { for x in x0..<x1 { pixels[y * width + x] = 0 } }
    }

    mutating func removeSpecks(minPixels: Int) {
        for component in components() where component.count < minPixels {
            for i in component { pixels[i] = 0 }
        }
    }

    /// 8-connected components as pixel indices.
    func components() -> [[Int]] {
        var seen = [Bool](repeating: false, count: width * height)
        var result: [[Int]] = []
        for start in 0..<(width * height) where pixels[start] != 0 && !seen[start] {
            var stack = [start]
            seen[start] = true
            var component: [Int] = []
            while let i = stack.popLast() {
                component.append(i)
                let x = i % width, y = i / width
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let j = ny * width + nx
                        if pixels[j] != 0 && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            result.append(component)
        }
        return result
    }

    /// Zhang–Suen thinning to a one-pixel-wide skeleton.
    func thinned() -> InkBitmap {
        var img = self
        guard width > 2, height > 2 else { return img }
        // Border pixels can't be tested with full neighborhoods; clear them.
        for x in 0..<width { img.pixels[x] = 0; img.pixels[(height - 1) * width + x] = 0 }
        for y in 0..<height { img.pixels[y * width] = 0; img.pixels[y * width + width - 1] = 0 }
        var changed = true
        var remove: [Int] = []
        while changed {
            changed = false
            for pass in 0..<2 {
                remove.removeAll(keepingCapacity: true)
                img.pixels.withUnsafeBufferPointer { p in
                    let w = width
                    for y in 1..<(height - 1) {
                        for x in 1..<(w - 1) where p[y * w + x] != 0 {
                            let i = y * w + x
                            let p2 = p[i - w] != 0, p3 = p[i - w + 1] != 0, p4 = p[i + 1] != 0, p5 = p[i + w + 1] != 0
                            let p6 = p[i + w] != 0, p7 = p[i + w - 1] != 0, p8 = p[i - 1] != 0, p9 = p[i - w - 1] != 0
                            let n = (p2, p3, p4, p5, p6, p7, p8, p9)
                            let b = [n.0, n.1, n.2, n.3, n.4, n.5, n.6, n.7].reduce(0) { $0 + ($1 ? 1 : 0) }
                            guard b >= 2 && b <= 6 else { continue }
                            let ring = [p2, p3, p4, p5, p6, p7, p8, p9, p2]
                            var a = 0
                            for k in 0..<8 where !ring[k] && ring[k + 1] { a += 1 }
                            guard a == 1 else { continue }
                            if pass == 0 {
                                guard !(p2 && p4 && p6), !(p4 && p6 && p8) else { continue }
                            } else {
                                guard !(p2 && p4 && p8), !(p2 && p6 && p8) else { continue }
                            }
                            remove.append(i)
                        }
                    }
                }
                for i in remove { img.pixels[i] = 0 }
                if !remove.isEmpty { changed = true }
            }
        }
        img.removeStaircases()
        return img
    }

    /// Thinning leaves staircases on thick diagonals: corner pixels whose orthogonal neighbours
    /// already touch diagonally. They make every pixel of a diagonal look like a junction, so they
    /// are removed whenever that keeps the neighbourhood connected (a minimal 8-connected skeleton).
    mutating func removeStaircases() {
        guard width > 2, height > 2 else { return }
        // Ring order: N, NE, E, SE, S, SW, W, NW.
        let ring = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]
        var changed = true
        while changed {
            changed = false
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) where pixels[y * width + x] != 0 {
                    let n = ring.map { pixels[(y + $0.1) * width + x + $0.0] != 0 }
                    let count = n.filter { $0 }.count
                    guard count >= 2 else { continue }
                    // A corner: two orthogonal neighbours that are diagonal to each other.
                    let corner = (n[0] && n[2]) || (n[2] && n[4]) || (n[4] && n[6]) || (n[6] && n[0])
                    guard corner else { continue }
                    // Neighbours stay one 8-connected group without this pixel?
                    var seen = [Bool](repeating: false, count: 8)
                    guard let start = n.firstIndex(of: true) else { continue }
                    var stack = [start]
                    seen[start] = true
                    while let i = stack.popLast() {
                        for j in 0..<8 where n[j] && !seen[j] {
                            let a = ring[i], b = ring[j]
                            if abs(a.0 - b.0) <= 1 && abs(a.1 - b.1) <= 1 { seen[j] = true; stack.append(j) }
                        }
                    }
                    guard (0..<8).allSatisfy({ !n[$0] || seen[$0] }) else { continue }
                    pixels[y * width + x] = 0
                    changed = true
                }
            }
        }
    }

    /// Enclosed background regions inside `box` (letters O, D, P, R, A → 1; B → 2; N, H, S → 0),
    /// returned as their horizontal centers (0 = box left edge, 1 = right edge).
    func holes(in box: CGRect, minPixels: Int = 4) -> [CGFloat] {
        let x0 = max(0, Int(box.minX) - 1), y0 = max(0, Int(box.minY) - 1)
        let x1 = min(width - 1, Int(box.maxX) + 1), y1 = min(height - 1, Int(box.maxY) + 1)
        guard x1 > x0, y1 > y0 else { return [] }
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var label = [Int](repeating: 0, count: w * h)  // 0 unvisited background, -1 ink, ≥2 regions
        for y in 0..<h { for x in 0..<w where self[x0 + x, y0 + y] { label[y * w + x] = -1 } }
        var next = 2
        var centers: [CGFloat] = []
        for start in 0..<(w * h) where label[start] == 0 {
            var stack = [start], count = 0, sumX = 0
            var touchesBorder = false
            label[start] = next
            while let i = stack.popLast() {
                count += 1
                let x = i % w, y = i / w
                sumX += x
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesBorder = true }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h, label[ny * w + nx] == 0 else { continue }
                    label[ny * w + nx] = next
                    stack.append(ny * w + nx)
                }
            }
            if !touchesBorder && count >= minPixels {
                let mx = CGFloat(sumX) / CGFloat(count)
                centers.append((mx + CGFloat(x0) - box.minX) / max(1, box.width))
            }
            next += 1
        }
        return centers
    }
}

/// Skeleton → polylines.
enum SkeletonTracer {
    private static let offsets = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]

    private static func neighbors(_ s: InkBitmap, _ x: Int, _ y: Int) -> [(Int, Int)] {
        offsets.compactMap { s[x + $0.0, y + $0.1] ? (x + $0.0, y + $0.1) : nil }
    }

    /// Pixel paths between endpoints/junctions, plus closed loops that have neither (an "O").
    static func paths(_ s: InkBitmap) -> [[CGPoint]] {
        let w = s.width
        func isNode(_ x: Int, _ y: Int) -> Bool { neighbors(s, x, y).count != 2 }
        func key(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) << 32 | Int64(max(a, b)) }
        var visitedEdge = Set<Int64>()
        var used = [Bool](repeating: false, count: s.width * s.height)
        var result: [[CGPoint]] = []

        for y in 0..<s.height {
            for x in 0..<s.width where s[x, y] && isNode(x, y) {
                for (nx, ny) in neighbors(s, x, y) {
                    guard !visitedEdge.contains(key(y * w + x, ny * w + nx)) else { continue }
                    var path = [CGPoint(x: x, y: y)]
                    var prev = (x, y), cur = (nx, ny)
                    visitedEdge.insert(key(y * w + x, ny * w + nx))
                    used[y * w + x] = true
                    while true {
                        path.append(CGPoint(x: cur.0, y: cur.1))
                        used[cur.1 * w + cur.0] = true
                        if isNode(cur.0, cur.1) { break }
                        guard let next = neighbors(s, cur.0, cur.1).first(where: { !($0.0 == prev.0 && $0.1 == prev.1) }) else { break }
                        let edge = key(cur.1 * w + cur.0, next.1 * w + next.0)
                        if visitedEdge.contains(edge) { break }
                        visitedEdge.insert(edge)
                        prev = cur
                        cur = next
                    }
                    result.append(path)
                }
            }
        }
        for y in 0..<s.height {
            for x in 0..<s.width where s[x, y] && !used[y * w + x] {
                var path = [CGPoint(x: x, y: y)]
                used[y * w + x] = true
                var prev = (x, y), cur = (x, y)
                while let next = neighbors(s, cur.0, cur.1).first(where: { !used[$0.1 * w + $0.0] && !($0.0 == prev.0 && $0.1 == prev.1) }) {
                    used[next.1 * w + next.0] = true
                    path.append(CGPoint(x: next.0, y: next.1))
                    prev = cur
                    cur = next
                }
                path.append(CGPoint(x: x, y: y))
                if path.count > 3 { result.append(path) }
            }
        }
        return result
    }

    /// Drops short spurs (thinning hairs) and joins paths that meet end-to-end where nothing
    /// else does, so a straight stroke is one path again.
    static func clean(_ input: [[CGPoint]], strokeWidth sw: CGFloat) -> [[CGPoint]] {
        var paths = input.filter { $0.count >= 2 }
        let tol = max(2, 1.5 * sw)
        func endsNear(_ q: CGPoint, excluding: Int) -> [(Int, Bool)] {
            var r: [(Int, Bool)] = []
            for (i, p) in paths.enumerated() where i != excluding {
                if hypot(p[0].x - q.x, p[0].y - q.y) < tol { r.append((i, true)) }
                if hypot(p[p.count - 1].x - q.x, p[p.count - 1].y - q.y) < tol { r.append((i, false)) }
            }
            return r
        }
        var pruned = true
        while pruned {
            pruned = false
            for i in paths.indices where length(paths[i]) < 2.5 * sw {
                let freeStart = endsNear(paths[i][0], excluding: i).isEmpty
                let freeEnd = endsNear(paths[i][paths[i].count - 1], excluding: i).isEmpty
                if freeStart != freeEnd {
                    paths.remove(at: i)
                    pruned = true
                    break
                }
            }
        }
        let connectors = Set(paths.indices.filter { length(paths[$0]) < 1.2 * sw && !endsNear(paths[$0][0], excluding: $0).isEmpty })
        paths = paths.enumerated().filter { !connectors.contains($0.offset) }.map(\.element)
        var joined = true
        while joined {
            joined = false
            outer: for i in paths.indices {
                for atStart in [true, false] {
                    let q = atStart ? paths[i][0] : paths[i][paths[i].count - 1]
                    let others = endsNear(q, excluding: i)
                    guard others.count == 1, let (j, jStart) = others.first, j != i else { continue }
                    var a = paths[i], b = paths[j]
                    if atStart { a.reverse() }
                    if !jStart { b.reverse() }
                    paths[i] = a + b.dropFirst()
                    paths.remove(at: j)
                    joined = true
                    break outer
                }
            }
        }
        return paths
    }

    static func length(_ p: [CGPoint]) -> CGFloat {
        zip(p, p.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Ramer–Douglas–Peucker.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var maxD: CGFloat = 0, index = 0
        for i in 1..<(points.count - 1) {
            let d = Geometry2D.distance(points[i], toSegment: first, last)
            if d > maxD { maxD = d; index = i }
        }
        guard maxD > tolerance else { return [first, last] }
        return simplify(Array(points[...index]), tolerance: tolerance).dropLast() + simplify(Array(points[index...]), tolerance: tolerance)
    }
}

/// Line art of one bitmap: simplified polylines plus the measured stroke width (pixels).
struct LineArt: Sendable {
    var bitmap: InkBitmap
    var polylines: [[CGPoint]]
    var strokeWidth: CGFloat

    init(bitmap: InkBitmap) {
        self.bitmap = bitmap
        let skeleton = bitmap.thinned()
        let sw = max(1, CGFloat(bitmap.inkCount) / CGFloat(max(1, skeleton.inkCount)))
        strokeWidth = sw
        polylines = SkeletonTracer.clean(SkeletonTracer.paths(skeleton), strokeWidth: sw)
            .map { SkeletonTracer.simplify($0, tolerance: max(1.5, sw * 0.9)) }
    }
}

enum Geometry2D {
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    static func distance(_ p: CGPoint, toLine a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l = hypot(dx, dy)
        guard l > 0.001 else { return distance(p, a) }
        return abs((p.x - a.x) * dy - (p.y - a.y) * dx) / l
    }

    static func distance(_ p: CGPoint, toRect r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// Angle in (−π, π].
    static func normalize(_ a: CGFloat) -> CGFloat {
        var a = a.truncatingRemainder(dividingBy: 2 * .pi)
        if a <= -.pi { a += 2 * .pi }
        if a > .pi { a -= 2 * .pi }
        return a
    }
}
