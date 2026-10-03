import SwiftUI

/// What Inky is doing; drives the character's pose and animation.
enum InkyCharacterState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
    case happy
}

/// Inky, the pen character. PLACEHOLDER art owned by the InkyCharacter module agent
/// (see README.md). Keep the type name and initializer; it is used by the floating
/// button, the ask popover, toasts and the sidebar at sizes from 20 to 64 pt.
struct InkyCharacterView: View {
    var state: InkyCharacterState = .idle
    var size: CGFloat = 32

    @State private var animate = false

    var body: some View {
        ZStack {
            // Pen body: a rounded nib tilted slightly.
            NibShape()
                .fill(Theme.accent)
                .frame(width: size * 0.62, height: size * 0.9)
            // Eyes
            HStack(spacing: size * 0.1) {
                eye
                eye
            }
            .offset(y: -size * 0.12)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(state == .thinking ? (animate ? 8 : -8) : -6))
        .offset(y: state == .listening && animate ? -size * 0.04 : 0)
        .scaleEffect(state == .happy && animate ? 1.08 : 1)
        .animation(isAnimating ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: animate)
        .onAppear { animate = isAnimating }
        .onChange(of: state) { _, _ in animate = isAnimating }
        .accessibilityHidden(true)
    }

    private var isAnimating: Bool {
        state != .idle
    }

    private var eye: some View {
        Capsule()
            .fill(.white)
            .frame(width: size * 0.09, height: state == .happy ? size * 0.05 : size * 0.13)
    }
}

/// A fountain-pen nib silhouette: round shoulders tapering to a point.
struct NibShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: rect.minX + w * 0.5, y: rect.maxY))
        p.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + h * 0.35),
            control1: CGPoint(x: rect.minX + w * 0.2, y: rect.minY + h * 0.75),
            control2: CGPoint(x: rect.minX, y: rect.minY + h * 0.55)
        )
        p.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY + h * 0.35),
            radius: w * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false
        )
        p.addCurve(
            to: CGPoint(x: rect.minX + w * 0.5, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.55),
            control2: CGPoint(x: rect.minX + w * 0.8, y: rect.minY + h * 0.75)
        )
        p.closeSubpath()
        return p
    }
}

#Preview {
    HStack(spacing: 24) {
        InkyCharacterView(state: .idle, size: 64)
        InkyCharacterView(state: .thinking, size: 64)
        InkyCharacterView(state: .happy, size: 64)
    }
    .padding()
}
