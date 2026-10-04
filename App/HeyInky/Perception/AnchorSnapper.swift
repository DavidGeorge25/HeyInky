import CoreGraphics
import UIKit

/// Makes Inky's pointers touch what they point at. A label's arrow tip that lands on empty
/// background of a placed image (a hair off the thing it names) is moved to the nearest drawn
/// content within a small radius. Tips already on content — including inside colored parts —
/// stay exactly where the model put them.
@MainActor
enum AnchorSnapper {
    /// Search radius as a fraction of the page width.
    static let radius = 0.015

    static func snapped(_ action: InkyAction, editor: PageEditorModel) -> InkyAction {
        guard case .label(var label) = action, label.arrow else { return action }
        for placed in editor.page.images.reversed() where placed.frame.contains(label.anchor) {
            guard let image = editor.store.image(placed.asset, in: editor.notebookID)?.cgImage,
                  let pixels = Pixels(image) else { break }
            let ix = Int((label.anchor.x - placed.frame.x) / placed.frame.width * Double(pixels.width))
            let iy = Int((label.anchor.y - placed.frame.y) / placed.frame.height * Double(pixels.height))
            guard pixels.isBackground(ix, iy) else { break }
            let r = Int(radius * Double(editor.page.width) / (placed.frame.width * Double(editor.page.width)) * Double(pixels.width))
            guard let hit = pixels.nearestContent(x: ix, y: iy, radius: max(2, r)) else { break }
            label.anchor = NormPoint(x: placed.frame.x + (Double(hit.x) + 0.5) / Double(pixels.width) * placed.frame.width,
                                     y: placed.frame.y + (Double(hit.y) + 0.5) / Double(pixels.height) * placed.frame.height)
            return .label(label)
        }
        return action
    }

    /// RGBA pixels of an image (downscaled to at most 900 px).
    struct Pixels {
        let width: Int
        let height: Int
        let data: [UInt8]

        init?(_ image: CGImage) {
            let scale = min(1, 900 / Double(max(image.width, image.height)))
            let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
            var buffer = [UInt8](repeating: 255, count: w * h * 4)
            let ok: Bool = buffer.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            width = w
            height = h
            data = buffer
        }

        /// Paper: very light and colorless (grid lines included).
        func isBackground(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            let i = (y * width + x) * 4
            let r = Double(data[i]), g = Double(data[i + 1]), b = Double(data[i + 2])
            let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
            let saturation = (max(r, g, b) - min(r, g, b)) / 255
            return lum > 0.8 && saturation < 0.2
        }

        func nearestContent(x: Int, y: Int, radius: Int) -> (x: Int, y: Int)? {
            var best: (Int, Int, Int)?
            for dy in -radius...radius {
                for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                    let px = x + dx, py = y + dy
                    guard px >= 0, py >= 0, px < width, py < height, !isBackground(px, py) else { continue }
                    let d = dx * dx + dy * dy
                    if best == nil || d < best!.2 { best = (px, py, d) }
                }
            }
            return best.map { ($0.0, $0.1) }
        }
    }
}
