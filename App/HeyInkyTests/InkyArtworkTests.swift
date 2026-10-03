import SwiftUI
import Testing
@testable import HeyInky

/// The app icon and launch image are rendered from `InkyAppIconArt` / `InkyLaunchArt`.
/// Re-render them into the asset catalog with `TEST_RUNNER_INKY_RECORD_ARTWORK=1`.
@MainActor
@Suite("Inky artwork")
struct InkyArtworkTests {
    static let assets = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("HeyInky/Resources/Assets.xcassets")
    static var iconURL: URL { assets.appendingPathComponent("AppIcon.appiconset/AppIcon.png") }
    static func launchURL(scale: Int) -> URL { assets.appendingPathComponent("LaunchInky.imageset/LaunchInky@\(scale)x.png") }

    var isRecording: Bool { ProcessInfo.processInfo.environment["INKY_RECORD_ARTWORK"] == "1" }

    func renderIcon() throws -> UIImage {
        try #require(Snapshot.render(InkyAppIconArt(), size: CGSize(width: 1024, height: 1024), scale: 1, opaque: true))
    }

    func renderLaunch(scale: Int) throws -> UIImage {
        let side = InkyLaunchArt.size
        return try #require(Snapshot.render(InkyLaunchArt(), size: CGSize(width: side, height: side), scale: CGFloat(scale), opaque: false))
    }

    @Test func appIconIsUpToDateOpaqueAndFullSize() throws {
        let rendered = try renderIcon()
        if isRecording { try rendered.pngData()?.write(to: Self.iconURL) }
        let icon = try #require(UIImage(contentsOfFile: Self.iconURL.path), "AppIcon.png missing; record with TEST_RUNNER_INKY_RECORD_ARTWORK=1")
        let cg = try #require(icon.cgImage)
        #expect(cg.width == 1024 && cg.height == 1024)
        #expect([.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo), "App icons must be opaque")
        let (diff, total) = Snapshot.difference(rendered, icon, threshold: 24)
        #expect(Double(diff) / Double(total) < 0.005, "AppIcon.png is out of date with InkyAppIconArt; re-record")
    }

    @Test(arguments: [2, 3])
    func launchImageIsUpToDate(scale: Int) throws {
        let rendered = try renderLaunch(scale: scale)
        if isRecording { try rendered.pngData()?.write(to: Self.launchURL(scale: scale)) }
        let image = try #require(UIImage(contentsOfFile: Self.launchURL(scale: scale).path))
        let cg = try #require(image.cgImage)
        #expect(cg.width == Int(InkyLaunchArt.size) * scale)
        let (diff, total) = Snapshot.difference(rendered, image, threshold: 24)
        #expect(Double(diff) / Double(total) < 0.005, "LaunchInky@\(scale)x.png is out of date; re-record")
    }

    @Test func iconReadsAtSmallSizes() throws {
        // At Spotlight/Settings size Inky should still be a clear, high-contrast shape.
        let small = try #require(Snapshot.render(InkyAppIconArt(side: 58), size: CGSize(width: 58, height: 58), scale: 1, opaque: true))
        let pixels = try #require(Snapshot.rgba(small))
        var dark = 0
        for i in stride(from: 0, to: pixels.bytes.count, by: 4) where Int(pixels.bytes[i]) + Int(pixels.bytes[i + 1]) < 260 {
            dark += 1
        }
        let fraction = Double(dark) / Double(58 * 58)
        #expect(fraction > 0.12 && fraction < 0.5, "Inky covers a solid part of the icon (\(fraction))")
    }
}
