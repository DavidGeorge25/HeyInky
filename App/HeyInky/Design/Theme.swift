import SwiftUI

/// Design tokens. One accent color (Inky ink), lots of whitespace, quiet surfaces.
enum Theme {
    static let accent = Color("AccentColor")
    static let accentUI = UIColor(named: "AccentColor") ?? UIColor(red: 0.357, green: 0.357, blue: 0.839, alpha: 1)

    static let canvasBackground = Color(red: 0.965, green: 0.965, blue: 0.957)
    static let canvasBackgroundUI = UIColor(red: 0.965, green: 0.965, blue: 0.957, alpha: 1)
    static let surface = Color.white
    static let hairline = Color.black.opacity(0.08)
    static let secondaryText = Color.black.opacity(0.5)

    static let cornerRadius: CGFloat = 14
    static let shadowColor = Color.black.opacity(0.08)

    static func highlightColor(_ color: HighlightColor) -> Color {
        switch color {
        case .yellow: Color(red: 1.0, green: 0.86, blue: 0.2)
        case .green: Color(red: 0.45, green: 0.86, blue: 0.5)
        case .blue: Color(red: 0.45, green: 0.72, blue: 1.0)
        case .pink: Color(red: 1.0, green: 0.55, blue: 0.75)
        case .orange: Color(red: 1.0, green: 0.65, blue: 0.3)
        }
    }

    /// Handwriting font for fillText; Noteworthy ships with iPadOS.
    static func handwriting(size: CGFloat) -> Font {
        .custom("Noteworthy-Bold", size: size)
    }
}

extension View {
    /// Floating card look used by popovers, toasts and cards.
    func inkySurface(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.shadowColor, radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }
}
