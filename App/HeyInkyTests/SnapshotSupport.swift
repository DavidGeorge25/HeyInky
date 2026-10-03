import Foundation
import SwiftUI
import Testing
import UIKit

/// Minimal image snapshots: render a view with `ImageRenderer`, compare against a PNG in
/// `HeyInkyTests/__Snapshots__/`. Record (or re-record) references with
/// `TEST_RUNNER_INKY_RECORD_SNAPSHOTS=1 xcodebuild test …`. A missing reference is recorded
/// and the test fails once so new references never pass silently.
@MainActor
enum Snapshot {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__")

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["INKY_RECORD_SNAPSHOTS"] == "1"
    }

    static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2, opaque: Bool = true) -> UIImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.isOpaque = opaque
        return renderer.uiImage
    }

    /// - Parameters:
    ///   - tolerance: fraction of pixels allowed to differ by more than `pixelThreshold`.
    static func assertMatches<V: View>(
        _ view: V, size: CGSize, named name: String, folder: String,
        scale: CGFloat = 2, tolerance: Double = 0.005, pixelThreshold: Int = 24,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let image = try #require(render(view, size: size, scale: scale), sourceLocation: sourceLocation)
        let data = try #require(image.pngData(), sourceLocation: sourceLocation)
        let url = directory.appendingPathComponent(folder).appendingPathComponent("\(name).png")
        let fm = FileManager.default

        if isRecording || !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            if !isRecording {
                Issue.record("Recorded new reference \(folder)/\(name).png; re-run to compare.", sourceLocation: sourceLocation)
            }
            return
        }

        let reference = try #require(UIImage(contentsOfFile: url.path), sourceLocation: sourceLocation)
        let (diff, total) = difference(image, reference, threshold: pixelThreshold)
        let fraction = total == 0 ? 1 : Double(diff) / Double(total)
        if fraction > tolerance {
            let failure = fm.temporaryDirectory.appendingPathComponent("snapshot-failures/\(folder)-\(name).png")
            try? fm.createDirectory(at: failure.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: failure)
            Issue.record(
                "\(folder)/\(name): \(diff) of \(total) pixels differ (\(String(format: "%.2f", fraction * 100))%). Actual image: \(failure.path)",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Number of pixels whose largest channel difference exceeds `threshold` (0…255).
    /// Images of different pixel sizes count as fully different.
    static func difference(_ a: UIImage, _ b: UIImage, threshold: Int) -> (Int, Int) {
        guard let pa = rgba(a), let pb = rgba(b), pa.width == pb.width, pa.height == pb.height else {
            return (1, 1)
        }
        var diff = 0
        for i in stride(from: 0, to: pa.bytes.count, by: 4) {
            var worst = 0
            for c in 0..<4 { worst = max(worst, abs(Int(pa.bytes[i + c]) - Int(pb.bytes[i + c]))) }
            if worst > threshold { diff += 1 }
        }
        return (diff, pa.width * pa.height)
    }

    static func rgba(_ image: UIImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (bytes, w, h)
    }
}
