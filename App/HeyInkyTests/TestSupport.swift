import Foundation
import UIKit
@testable import HeyInky

enum Fixtures {
    /// Shared fixtures from /shared/fixtures, copied into the test bundle as a folder.
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "fixtures/\(name).json"])
        }
        return try Data(contentsOf: url)
    }

    static func response(_ name: String) throws -> InkyResponse {
        try JSONDecoder().decode(InkyResponse.self, from: data(name))
    }

    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HeyInkyTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sampleRequest(question: String = "highlight the title", lasso: NormRect? = nil) -> InkyRequest {
        InkyRequest(
            question: question,
            images: [InkyImage(pngData: Data([0x89, 0x50, 0x4E, 0x47]), caption: "Full page with coordinate grid:")],
            recognizedText: [RecognizedTextLine(text: "Lecture 7", box: NormRect(x: 0.1, y: 0.07, width: 0.5, height: 0.04))],
            lassoRegion: lasso,
            pageAspectRatio: 816.0 / 1056.0,
            notebookTitle: "Chem"
        )
    }
}

private final class BundleToken {}

extension UIImage {
    /// RGBA of the pixel at a point in image (pixel) coordinates.
    func pixel(at point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        guard let cg = cgImage else { return (0, 0, 0, 0) }
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0, 0) }
        ctx.draw(cg, in: CGRect(x: -point.x, y: point.y - CGFloat(cg.height) + 1, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (CGFloat(data[0]) / 255, CGFloat(data[1]) / 255, CGFloat(data[2]) / 255, CGFloat(data[3]) / 255)
    }

    /// Fraction of pixels in `rect` (pixel coords) with alpha above a threshold.
    func coverage(in rect: CGRect, step: CGFloat = 4) -> Double {
        var hit = 0, total = 0
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                total += 1
                if pixel(at: CGPoint(x: x, y: y)).a > 0.1 { hit += 1 }
                x += step
            }
            y += step
        }
        return total == 0 ? 0 : Double(hit) / Double(total)
    }
}
