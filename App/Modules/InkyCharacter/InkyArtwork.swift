import SwiftUI

/// Source artwork for the app icon and launch screen. The PNGs in the asset catalog are
/// rendered from these views by `InkyArtworkTests` (`TEST_RUNNER_INKY_RECORD_ARTWORK=1`).
enum InkyArtwork {
    static let paper = Color(red: 0.973, green: 0.969, blue: 0.957)
    static let paperShade = Color(red: 0.925, green: 0.922, blue: 0.976)

    /// Inky mid-stroke, finishing a highlighter swipe: what the app does, in one picture.
    static var iconPose: InkyPose {
        var pose = InkyPose()
        pose.tilt = -12
        pose.gaze = CGPoint(x: 0.15, y: 0.2)
        pose.dropTilt = -6
        return pose
    }
}

/// 1024 × 1024 app icon (opaque, square; iPadOS applies the mask).
struct InkyAppIconArt: View {
    var side: CGFloat = 1024

    var body: some View {
        let u = side / 1024
        let figure: CGFloat = 860 * u
        // Nib tip lands at the end of the highlighter swipe.
        let nib = CGPoint(x: 650 * u, y: 884 * u)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [InkyArtwork.paper, InkyArtwork.paperShade], startPoint: .top, endPoint: .bottom)

            // Ruled paper.
            ForEach(1..<11, id: \.self) { i in
                Rectangle()
                    .fill(Theme.accent.opacity(0.07))
                    .frame(width: side, height: 4 * u)
                    .offset(y: CGFloat(i) * 92 * u + 10 * u)
            }

            MarkerSwipe(scale: 6 * u)
                .fill(Theme.highlightColor(.yellow).opacity(0.62))
                .frame(width: 560 * u, height: 100 * u)
                .offset(x: 96 * u, y: nib.y - 76 * u)

            InkyFigure(pose: InkyArtwork.iconPose, size: figure)
                .shadow(color: InkyPalette.ink.opacity(0.12), radius: 18 * u, y: 12 * u)
                .offset(x: nib.x - figure / 2, y: nib.y - InkyDrawing.nibTipInFrame.y * figure)
        }
        .frame(width: side, height: side)
        .clipped()
    }
}

/// Launch screen image: Inky alone, centered on the paper-colored launch background.
struct InkyLaunchArt: View {
    static let size: CGFloat = 132

    var body: some View {
        InkyFigure(pose: InkyMotion.reference(.idle), size: Self.size)
    }
}

#Preview("Icon") {
    InkyAppIconArt(side: 512)
}
