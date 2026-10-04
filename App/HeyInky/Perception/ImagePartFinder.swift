import CoreGraphics
import Foundation

/// The parts of a picture — filled regions (a nucleus, a mitochondrion, a lung lobe) and clusters of
/// line marks (folded ER membranes, a Golgi stack) — found by color segmentation, so Inky can name
/// them by id and the app can point exactly at them (`PartLabeler`).
///
/// Pipeline: downsample → dark (line) mask → flood-fill regions of similar color between the lines →
/// drop specks and the background → per region an interior point (farthest from its edges), its
/// outer outline (on the drawn line when there is one) and the region around it; dark strokes that
/// aren't outlines, grouped by proximity, become "marks" parts.
enum ImagePartFinder {
    struct Part: Sendable, Equatable {
        enum Kind: String, Sendable { case region, marks }
        var kind: Kind
        /// Normalized to the image (0…1).
        var box: CGRect
        var point: CGPoint
        var outline: [CGPoint]
        /// Mean color (r, g, b), 0…1.
        var color: [Double]
        /// Share of the image's area (regions: pixels; marks: bounding box).
        var area: Double
        /// Index of the enclosing part.
        var parent: Int?
        var outlined: Bool
        var detailed: Bool
        /// Bounding-box aspect (long side / short side) and how much of the box the part fills.
        var elongation: Double
        var fill: Double
    }

    /// - Parameter exclude: normalized areas to ignore (lines of prose on a slide).
    static func parts(in image: CGImage, exclude: [CGRect] = [], maxSide: Int = 400) -> [Part] {
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let w = max(8, Int(CGFloat(image.width) * scale)), h = max(8, Int(CGFloat(image.height) * scale))
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            for r in exclude {
                // CG's origin is bottom-left.
                ctx.fill(CGRect(x: r.minX * CGFloat(w), y: (1 - r.maxY) * CGFloat(h), width: r.width * CGFloat(w), height: r.height * CGFloat(h)))
            }
            return true
        }
        guard drawn else { return [] }
        let n = w * h
        var red = [Float](repeating: 0, count: n), green = red, blue = red, lum = red
        for i in 0..<n {
            red[i] = Float(rgba[i * 4]) / 255; green[i] = Float(rgba[i * 4 + 1]) / 255; blue[i] = Float(rgba[i * 4 + 2]) / 255
            lum[i] = 0.299 * red[i] + 0.587 * green[i] + 0.114 * blue[i]
        }
        let dark = lum.map { $0 < 0.45 }
        func colorDistance(_ a: Int, _ r: Float, _ g: Float, _ b: Float) -> Float {
            let dr = red[a] - r, dg = green[a] - g, db = blue[a] - b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }

        // 1. Regions: flood fill over non-dark pixels of similar color.
        var label = [Int32](repeating: -1, count: n)
        struct Region { var count = 0; var r = 0.0, g = 0.0, b = 0.0; var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0; var border = 0 }
        var regions: [Region] = []
        var stack: [Int] = []
        for seed in 0..<n where label[seed] == -1 && !dark[seed] {
            let id = Int32(regions.count)
            var region = Region()
            var mr = red[seed], mg = green[seed], mb = blue[seed]
            label[seed] = id
            stack.append(seed)
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                region.count += 1
                region.r += Double(red[p]); region.g += Double(green[p]); region.b += Double(blue[p])
                region.minX = min(region.minX, x); region.maxX = max(region.maxX, x)
                region.minY = min(region.minY, y); region.maxY = max(region.maxY, y)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { region.border += 1 }
                // Running mean keeps a slow gradient in one region but stops at a real color change.
                let k = Float(region.count)
                mr += (red[p] - mr) / k; mg += (green[p] - mg) / k; mb += (blue[p] - mb) / k
                for q in [x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, y > 0 ? p - w : -1, y < h - 1 ? p + w : -1] where q >= 0 {
                    guard label[q] == -1, !dark[q] else { continue }
                    if colorDistance(q, red[p], green[p], blue[p]) < 0.06 && colorDistance(q, mr, mg, mb) < 0.16 {
                        label[q] = id
                        stack.append(q)
                    }
                }
            }
            regions.append(region)
        }

        let perimeter = 2 * (w + h)
        let minArea = max(24, Int(Double(n) * 0.0025))
        func mean(_ r: Region) -> [Double] { [r.r / Double(r.count), r.g / Double(r.count), r.b / Double(r.count)] }
        func luminance(_ c: [Double]) -> Double { 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2] }
        func saturation(_ c: [Double]) -> Double { (c.max() ?? 0) - (c.min() ?? 0) }
        var isBackground = [Bool](repeating: false, count: regions.count)
        for (i, r) in regions.enumerated() where r.border > 0 {
            let c = mean(r)
            if (luminance(c) > 0.9 && saturation(c) < 0.08) || r.border > perimeter / 3 { isBackground[i] = true }
        }
        let kept = regions.indices.filter { regions[$0].count >= minArea && !isBackground[$0] }
        guard !kept.isEmpty || dark.contains(true) else { return [] }

        // 2. Distance from each pixel to the nearest pixel of another label (chamfer 3-4).
        var dist = [Int32](repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                let l = label[p]
                let edge = x == 0 || y == 0 || x == w - 1 || y == h - 1
                    || label[p - 1] != l || label[p + 1] != l || label[p - w] != l || label[p + w] != l
                dist[p] = edge ? 0 : Int32.max / 2
            }
        }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let p = y * w + x
                dist[p] = min(dist[p], dist[p - 1] + 3, dist[p - w] + 3, dist[p - w - 1] + 4, dist[p - w + 1] + 4)
            }
        }
        for y in stride(from: h - 2, through: 1, by: -1) {
            for x in stride(from: w - 2, through: 1, by: -1) {
                let p = y * w + x
                dist[p] = min(dist[p], dist[p + 1] + 3, dist[p + w] + 3, dist[p + w + 1] + 4, dist[p + w - 1] + 4)
            }
        }
        var bestPixel = [Int](repeating: -1, count: regions.count)
        for p in 0..<n {
            let l = Int(label[p])
            guard l >= 0 else { continue }
            if bestPixel[l] < 0 || dist[p] > dist[bestPixel[l]] { bestPixel[l] = p }
        }

        // 3. Outline (rays from the box center: last pixel of the region, then across a drawn line)
        //    and the label found just beyond it (the enclosing region).
        func norm(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x + 0.5) / Double(w), y: (y + 0.5) / Double(h)) }
        struct Rim { var outline: [CGPoint]; var outlined: Bool; var parent: Int? }
        func rim(of id: Int) -> Rim {
            let r = regions[id]
            let cx = Double(r.minX + r.maxX) / 2, cy = Double(r.minY + r.maxY) / 2
            let reach = Double(max(r.maxX - r.minX, r.maxY - r.minY)) + 4
            var outline: [CGPoint] = []
            var lined = 0, rays = 0
            var beyond: [Int: Int] = [:]
            for k in 0..<36 {
                let a = Double(k) * .pi / 18
                let dx = cos(a), dy = sin(a)
                var last: (Double, Double)?
                var t = 0.0
                while t < reach {
                    let x = Int((cx + dx * t).rounded()), y = Int((cy + dy * t).rounded())
                    guard x >= 0, y >= 0, x < w, y < h else { break }
                    if label[y * w + x] == Int32(id) { last = (t, 0) }
                    t += 0.5
                }
                guard let (tLast, _) = last else { continue }
                rays += 1
                // Walk across a drawn outline, if there is one.
                var s = tLast + 0.5, darkStart: Double?, darkEnd: Double?
                while s < tLast + 8 {
                    let x = Int((cx + dx * s).rounded()), y = Int((cy + dy * s).rounded())
                    guard x >= 0, y >= 0, x < w, y < h else { break }
                    let p = y * w + x
                    if dark[p] { if darkStart == nil { darkStart = s }; darkEnd = s } else if darkStart != nil { break }
                    s += 0.5
                }
                let tEdge: Double
                if let a0 = darkStart, let a1 = darkEnd { tEdge = (a0 + a1) / 2; lined += 1 } else { tEdge = tLast }
                outline.append(norm(cx + dx * tEdge, cy + dy * tEdge))
                // What's just outside.
                let probe = (darkEnd ?? tLast) + 2.5
                let x = Int((cx + dx * probe).rounded()), y = Int((cy + dy * probe).rounded())
                if x >= 0, y >= 0, x < w, y < h {
                    let l = Int(label[y * w + x])
                    if l >= 0 && l != id { beyond[l, default: 0] += 1 }
                }
            }
            let parent = beyond.filter { kept.contains($0.key) && $0.value * 2 >= rays }.max { $0.value < $1.value }?.key
            return Rim(outline: outline, outlined: rays > 0 && Double(lined) / Double(rays) > 0.6, parent: parent)
        }

        var parts: [Part] = []
        var partOfRegion: [Int: Int] = [:]
        var rims: [Int: Rim] = [:]
        for id in kept {
            let r = regions[id]
            let rimInfo = rim(of: id)
            rims[id] = rimInfo
            let bw = r.maxX - r.minX + 1, bh = r.maxY - r.minY + 1
            let p = bestPixel[id]
            partOfRegion[id] = parts.count
            parts.append(Part(
                kind: .region,
                box: CGRect(x: Double(r.minX) / Double(w), y: Double(r.minY) / Double(h), width: Double(bw) / Double(w), height: Double(bh) / Double(h)),
                point: norm(Double(p % w), Double(p / w)),
                outline: rimInfo.outline, color: mean(r), area: Double(r.count) / Double(n), parent: nil,
                outlined: rimInfo.outlined, detailed: false,
                elongation: Double(max(bw, bh)) / Double(max(1, min(bw, bh))), fill: Double(r.count) / Double(bw * bh)
            ))
        }
        for id in kept {
            if let parent = rims[id]?.parent, let pi = partOfRegion[parent], let me = partOfRegion[id] { parts[me].parent = pi }
        }

        // 4. Dark strokes: components that aren't some region's outline are details (small, inside
        //    one region) or marks of their own, grouped when close.
        var comp = [Int32](repeating: -1, count: n)
        struct Stroke { var count = 0; var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0; var r = 0.0, g = 0.0, b = 0.0; var around: [Int: Int] = [:] }
        var strokes: [Stroke] = []
        for seed in 0..<n where dark[seed] && comp[seed] == -1 {
            let id = Int32(strokes.count)
            var s = Stroke()
            comp[seed] = id
            stack.append(seed)
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                s.count += 1
                s.r += Double(red[p]); s.g += Double(green[p]); s.b += Double(blue[p])
                s.minX = min(s.minX, x); s.maxX = max(s.maxX, x); s.minY = min(s.minY, y); s.maxY = max(s.maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let qx = x + dx, qy = y + dy
                        guard qx >= 0, qy >= 0, qx < w, qy < h else { continue }
                        let q = qy * w + qx
                        if dark[q] {
                            if comp[q] == -1 { comp[q] = id; stack.append(q) }
                        } else if label[q] >= 0 {
                            s.around[Int(label[q]), default: 0] += 1
                        }
                    }
                }
            }
            strokes.append(s)
        }
        let maxSidePixels = Double(max(w, h))
        var looseStrokes: [Int] = []
        for (si, s) in strokes.enumerated() where s.count >= 6 {
            let sb = CGRect(x: s.minX, y: s.minY, width: s.maxX - s.minX + 1, height: s.maxY - s.minY + 1)
            // An outline: hugs a kept region's box.
            let isOutline = kept.contains { id in
                let r = regions[id]
                let rb = CGRect(x: r.minX, y: r.minY, width: r.maxX - r.minX + 1, height: r.maxY - r.minY + 1).insetBy(dx: -4, dy: -4)
                return rb.contains(sb) && sb.width > rb.width * 0.7 && sb.height > rb.height * 0.7
            }
            if isOutline { continue }
            // Mostly surrounded by one region.
            let host = s.around.max { $0.value < $1.value }?.key
            if let host, let hp = partOfRegion[host] {
                let r = regions[host]
                let hostBox = Double((r.maxX - r.minX + 1) * (r.maxY - r.minY + 1))
                if hostBox < 5 * Double(sb.width * sb.height) { parts[hp].detailed = true; continue }
            }
            if Double(max(sb.width, sb.height)) < maxSidePixels * 0.03 { continue }
            looseStrokes.append(si)
        }
        // Group loose strokes that are close together (parallel folds, a stack of arcs).
        let gap = maxSidePixels * 0.04
        var group = Array(looseStrokes.indices)
        func find(_ i: Int) -> Int { var i = i; while group[i] != i { group[i] = group[group[i]]; i = group[i] }; return i }
        func rect(_ s: Stroke) -> CGRect { CGRect(x: s.minX, y: s.minY, width: s.maxX - s.minX + 1, height: s.maxY - s.minY + 1) }
        for a in looseStrokes.indices {
            for b in (a + 1)..<looseStrokes.count where rect(strokes[looseStrokes[a]]).insetBy(dx: -gap / 2, dy: -gap / 2).intersects(rect(strokes[looseStrokes[b]]).insetBy(dx: -gap / 2, dy: -gap / 2)) {
                group[find(a)] = find(b)
            }
        }
        var groups: [Int: [Int]] = [:]
        for a in looseStrokes.indices { groups[find(a), default: []].append(looseStrokes[a]) }
        for members in groups.values {
            var box = CGRect.null
            var count = 0, r = 0.0, g = 0.0, b = 0.0
            var around: [Int: Int] = [:]
            for m in members {
                let s = strokes[m]
                box = box.union(rect(s)); count += s.count
                r += s.r; g += s.g; b += s.b
                for (k, v) in s.around { around[k, default: 0] += v }
            }
            guard count >= 20, Double(max(box.width, box.height)) >= maxSidePixels * 0.04 else { continue }
            // The point: the stroke pixel nearest the group's center (so a leader ends on a line).
            let c = CGPoint(x: box.midX, y: box.midY)
            let memberSet = Set(members.map(Int32.init))
            var best = -1, bestD = Double.infinity
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX) {
                    let p = y * w + x
                    guard dark[p], memberSet.contains(comp[p]) else { continue }
                    let d = hypot(Double(x) - c.x, Double(y) - c.y)
                    if d < bestD { bestD = d; best = p }
                }
            }
            guard best >= 0 else { continue }
            let host = around.max { $0.value < $1.value }?.key
            parts.append(Part(
                kind: .marks,
                box: CGRect(x: box.minX / Double(w), y: box.minY / Double(h), width: box.width / Double(w), height: box.height / Double(h)),
                point: norm(Double(best % w), Double(best / w)), outline: [],
                color: [r / Double(count), g / Double(count), b / Double(count)],
                area: Double(box.width * box.height) / Double(n), parent: host.flatMap { partOfRegion[$0] },
                outlined: false, detailed: false,
                elongation: Double(max(box.width, box.height)) / Double(max(1, min(box.width, box.height))), fill: 0
            ))
        }
        return parts
    }

    // MARK: Describing

    static func colorName(_ c: [Double]) -> String {
        guard c.count == 3 else { return "gray" }
        let r = c[0], g = c[1], b = c[2]
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2, s = mx - mn
        if s < 0.035 || (s < 0.08 && l < 0.85) {
            if l > 0.85 { return "white" }
            if l < 0.25 { return "black" }
            return l > 0.6 ? "light gray" : "gray"
        }
        var hue: Double
        if mx == r { hue = (g - b) / s } else if mx == g { hue = 2 + (b - r) / s } else { hue = 4 + (r - g) / s }
        hue = (hue * 60).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let name: String
        switch hue {
        case ..<15, 345...: name = l > 0.75 ? "pink" : "red"
        case ..<40: name = l < 0.4 ? "brown" : "orange"
        case ..<65: name = l < 0.4 ? "olive" : "yellow"
        case ..<165: name = "green"
        case ..<195: name = "teal"
        case ..<255: name = "blue"
        case ..<290: name = "purple"
        default: name = "pink"
        }
        if s < 0.08 { return "pale " + name }
        if l > 0.8 { return "light " + name }
        if l < 0.35 { return "dark " + name }
        return name
    }

    static func shapeName(_ p: Part) -> String {
        if p.kind == .marks { return p.elongation > 3 ? "long lines" : "lines" }
        if p.fill > 0.62 && p.elongation < 1.35 { return "round" }
        if p.fill > 0.62 && p.elongation < 2.6 { return "oval" }
        if p.elongation >= 2.6 { return "elongated" }
        return "irregular"
    }
}
