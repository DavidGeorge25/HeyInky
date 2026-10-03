import SwiftUI

/// Minimal SVG path-data parser for RDKit's output (M, L, H, V, Q, C, A, Z; absolute and
/// relative). RDKit emits absolute M/L/Q/Z for bonds and glyph outlines.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var tokens = Tokenizer(d)
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero

        while let token = tokens.peek() {
            if case .command(let c) = token {
                tokens.next()
                command = c
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                    continue
                }
            }
            let relative = command.isLowercase
            func point() -> CGPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased().first! {
            case "M":
                guard let p = point() else { return path }
                path.move(to: p)
                current = p; start = p
                command = relative ? "l" : "L" // implicit lineto after the first pair
            case "L":
                guard let p = point() else { return path }
                path.addLine(to: p); current = p
            case "H":
                guard let x = tokens.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = tokens.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case "Q":
                guard let c1 = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c1); current = p
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); current = p
            case "A":
                guard let rx = tokens.number(), let ry = tokens.number(), let rotation = tokens.number(),
                      let large = tokens.number(), let sweep = tokens.number(), let p = point() else { return path }
                addArc(to: &path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large != 0, sweep: sweep != 0)
                current = p
            default:
                tokens.next() // unknown command: skip a token so we always make progress
            }
        }
        return path
    }

    /// SVG endpoint arc → center parameterization (SVG spec F.6.5), drawn as an ellipse arc.
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = (max(0, num) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2,
                             y: sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2)
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let steps = max(4, Int(abs(delta) / (.pi / 8)))
        for i in 1...steps {
            let t = theta1 + delta * CGFloat(i) / CGFloat(steps)
            let x = rx * cos(t), y = ry * sin(t)
            path.addLine(to: CGPoint(x: center.x + cosPhi * x - sinPhi * y, y: center.y + sinPhi * x + cosPhi * y))
        }
    }

    private struct Tokenizer {
        enum Token { case command(Character), number(CGFloat) }
        private let chars: [Character]
        private var i = 0

        init(_ s: String) { chars = Array(s) }

        private mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" { i += 1 }
        }

        mutating func peek() -> Token? {
            skipSeparators()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c.isLetter && c != "e" && c != "E" { return .command(c) }
            let save = i
            defer { i = save }
            return number().map { .number($0) }
        }

        mutating func next() {
            skipSeparators()
            guard i < chars.count else { return }
            let c = chars[i]
            if c.isLetter && c != "e" && c != "E" { i += 1 } else { _ = number() }
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = i
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            var seenDot = false, seenExp = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { i += 1 }
                else if c == "." && !seenDot && !seenExp { seenDot = true; i += 1 }
                else if (c == "e" || c == "E") && !seenExp { seenExp = true; i += 1; if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 } }
                else { break }
            }
            guard i > begin, let v = Double(String(chars[begin..<i])) else { i = begin; return nil }
            return CGFloat(v)
        }
    }
}
