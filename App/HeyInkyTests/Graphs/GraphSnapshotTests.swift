import SwiftUI
import Testing
@testable import HeyInky

/// Snapshot tests of every preset, light and dark, drawn by the native renderer (the same
/// drawing used when a card is flattened into the page).
///
/// References live in `__Snapshots__/` next to this file. A missing reference is recorded and
/// the test fails once; re-record all with `TEST_RUNNER_INKY_RECORD_SNAPSHOTS=1 xcodebuild test …`.
@MainActor
@Suite("Graph preset snapshots")
struct GraphSnapshotTests {
    static let size = CGSize(width: 480, height: 320)
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__")

    @Test(arguments: GraphPresets.all.map(\.id), [false, true])
    func preset(_ id: String, dark: Bool) throws {
        let preset = try #require(GraphPresets.preset(id: id))
        let doc = GraphDocument(spec: preset.spec)
        let scene = GraphScene(document: doc, theme: dark ? .dark : .light)
        let image = try #require(GraphPlotView.image(document: doc, scene: scene, size: Self.size, scale: 1))
        try assertSnapshot(image, named: "graph-\(id)-\(dark ? "dark" : "light")")
    }

    @Test func snapshotsActuallyDrawCurves() throws {
        // Guard against a renderer that silently draws nothing: the curve color must appear.
        let doc = GraphDocument(spec: GraphPresets.harmonic.spec)
        let scene = GraphScene(document: doc, theme: .light)
        let image = try #require(GraphPlotView.image(document: doc, scene: scene, size: Self.size, scale: 1))
        let pixels = try #require(RGBAImage(image))
        let indigo = pixels.count { r, g, b in abs(r - 91) < 30 && abs(g - 91) < 30 && abs(b - 214) < 30 }
        #expect(indigo > 300, "found \(indigo) indigo pixels")
    }

    func assertSnapshot(_ image: UIImage, named name: String) throws {
        let url = Self.directory.appendingPathComponent("\(name).png")
        let record = ProcessInfo.processInfo.environment["INKY_RECORD_SNAPSHOTS"] == "1"
        guard !record, let referenceData = try? Data(contentsOf: url), let reference = UIImage(data: referenceData) else {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try #require(image.pngData()).write(to: url)
            Issue.record("Recorded snapshot \(name). Re-run to compare.")
            return
        }
        let a = try #require(RGBAImage(image)), b = try #require(RGBAImage(reference))
        #expect(a.width == b.width && a.height == b.height, "\(name): size changed")
        guard a.width == b.width, a.height == b.height else { return }
        let diff = a.fractionDiffering(from: b, threshold: 24)
        if diff > 0.004 {
            let failure = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).failed.png")
            try? image.pngData()?.write(to: failure)
            Issue.record("\(name): \(String(format: "%.2f", diff * 100))% of pixels differ (see \(failure.path))")
        }
    }
}

/// 8-bit RGBA pixels of an image, for comparisons.
struct RGBAImage {
    let width: Int, height: Int
    let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        width = w; height = h
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        bytes = data
    }

    func count(where match: (Int, Int, Int) -> Bool) -> Int {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) { n, i in
            match(Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])) ? n + 1 : n
        }
    }

    func fractionDiffering(from other: RGBAImage, threshold: Int) -> Double {
        var differing = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let d = (0..<4).map { abs(Int(bytes[i + $0]) - Int(other.bytes[i + $0])) }.max() ?? 0
            if d > threshold { differing += 1 }
        }
        return Double(differing) / Double(width * height)
    }

    /// Pixels that differ noticeably from `background`.
    func inkCoverage(background: (Int, Int, Int)) -> Double {
        Double(count { r, g, b in abs(r - background.0) + abs(g - background.1) + abs(b - background.2) > 60 }) / Double(width * height)
    }
}
