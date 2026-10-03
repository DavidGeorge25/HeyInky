import SwiftUI
import Testing
import UIKit
@testable import HeyInky

/// Renders the molecule card with real RDKit output and compares it with reference PNGs in
/// `__Snapshots__/` next to this file. A missing reference is recorded (and the test fails
/// once so the recording is noticed); set `SNAPSHOT_RECORD=1` (TEST_RUNNER_SNAPSHOT_RECORD=1
/// from xcodebuild) to re-record after an intended visual change.
@MainActor
@Suite(.serialized)
struct MoleculeCardSnapshotTests {
    static let size = CGSize(width: 380, height: 270)

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var action: InsertMoleculeCardAction
        var dark = false
        var testDescription: String { name }
    }

    nonisolated static let cases: [Case] = [
        Case(name: "aspirin-all-groups", action: action("CC(=O)Oc1ccccc1C(=O)O")),
        Case(name: "penicillin-starred-lactam", action: action("CC1(C)S[C@@H]2[C@H](NC(=O)Cc3ccccc3)C(=O)N2[C@H]1C(=O)O", highlight: ["lactam", "C(=O)[OH]"], star: ["lactam"])),
        Case(name: "glucose-dark", action: action("OC[C@H]1O[C@@H](O)[C@H](O)[C@@H](O)[C@@H]1O"), dark: true),
        Case(name: "esterification-reaction", action: action("CCO.CC(=O)O>>CC(=O)OCC.O")),
    ]

    nonisolated static func action(_ smiles: String, highlight: [String] = [], star: [String] = []) -> InsertMoleculeCardAction {
        InsertMoleculeCardAction(smiles: smiles, near: NormRect(x: 0.1, y: 0.1, width: 0.4, height: 0.25), highlightGroups: highlight, starGroups: star, caption: nil)
    }

    @Test(arguments: cases)
    func cardMatchesSnapshot(_ c: Case) async throws {
        let analysis = try await MoleculeEngine.shared.analyze(smiles: c.action.smiles, highlightGroups: c.action.highlightGroups, starGroups: c.action.starGroups)
        #expect(analysis.ok)
        let view = MoleculeCardContent(action: c.action, phase: .ready(analysis))
            .frame(width: Self.size.width, height: Self.size.height)
            .background(c.dark ? Color.black : Color.white)
            .environment(\.colorScheme, c.dark ? .dark : .light)
        let image = try #require(Self.render(view))
        try Snapshot.assertMatches(image, named: c.name)
    }

    @Test func invalidSmilesShowsCalmErrorWithRawSmiles() throws {
        let action = Self.action("C1CC((")
        let view = MoleculeCardContent(action: action, phase: .failed("RDKit could not parse this SMILES."))
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color.white)
        let image = try #require(Self.render(view))
        try Snapshot.assertMatches(image, named: "invalid-smiles")
    }

    static func render<V: View>(_ view: V) -> UIImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.uiImage
    }
}

enum Snapshot {
    static func directory(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("__Snapshots__")
    }

    static var recording: Bool { ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1" }

    static func assertMatches(_ image: UIImage, named name: String, tolerance: Double = 0.006, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let dir = directory()
        let url = dir.appendingPathComponent("\(name).png")
        let png = try #require(image.pngData())
        if recording || !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url)
            Issue.record("Recorded snapshot \(name).png — re-run to compare.", sourceLocation: sourceLocation)
            return
        }
        let reference = try #require(UIImage(contentsOfFile: url.path))
        let diff = difference(image, reference)
        if diff > tolerance {
            let failed = dir.appendingPathComponent("\(name).failed.png")
            try? png.write(to: failed)
            Issue.record("Snapshot \(name) differs in \(String(format: "%.2f", diff * 100))% of pixels (see \(failed.lastPathComponent)).", sourceLocation: sourceLocation)
        }
    }

    /// Fraction of pixels whose RGBA differs by more than ~10%.
    static func difference(_ a: UIImage, _ b: UIImage) -> Double {
        guard let pa = pixels(a), let pb = pixels(b), pa.width == pb.width, pa.height == pb.height else { return 1 }
        var differing = 0
        for i in stride(from: 0, to: pa.data.count, by: 4) {
            let delta = (0..<4).map { abs(Int(pa.data[i + $0]) - Int(pb.data[i + $0])) }.max() ?? 0
            if delta > 26 { differing += 1 }
        }
        return Double(differing) / Double(pa.width * pa.height)
    }

    private static func pixels(_ image: UIImage) -> (data: [UInt8], width: Int, height: Int)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (data, w, h)
    }
}
