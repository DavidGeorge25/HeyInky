import SwiftUI

/// Small pieces of Inky's visual language shared by the ask popover, toasts and sidebar.
enum InkyStyle {
    /// Inky's voice: SF Rounded.
    static func voice(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let tint = Theme.accent.opacity(0.09)
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.78)
}

/// Inky in a soft tinted circle. When `isAway` (Inky is out drawing on the page) the seat
/// shows a single ink drop instead, so there is never more than one Inky on screen.
struct InkyAvatar: View {
    var state: InkyCharacterState = .idle
    var size: CGFloat = 34
    var isAway = false

    var body: some View {
        ZStack {
            Circle().fill(InkyStyle.tint)
            if isAway {
                InkyAwayDrop(size: size * 0.32)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                InkyCharacterView(state: state, size: size * 0.86)
                    .offset(y: size * 0.02)
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .animation(InkyStyle.spring, value: isAway)
        .accessibilityHidden(true)
    }
}

/// A gently pulsing ink drop: "Inky is out on your page".
struct InkyAwayDrop: View {
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? 0 : sin(t * 2 * .pi / 1.6)
            InkyDropShape()
                .fill(InkyPalette.ink.opacity(0.75))
                .frame(width: size * 0.7, height: size)
                .scaleEffect(1 + 0.08 * pulse, anchor: .bottom)
        }
        .frame(width: size, height: size)
    }
}

/// Three ink dots that fill in turn, like Inky's thought bubbles.
struct InkyThinkingDots: View {
    var dotSize: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate / 1.1
            HStack(spacing: dotSize * 0.7) {
                ForEach(0..<3, id: \.self) { i in
                    let local = (phase - Double(i) * 0.18).truncatingRemainder(dividingBy: 1)
                    let v = reduceMotion ? 0.7 : 0.3 + 0.7 * max(0, sin(local * 2 * .pi))
                    Circle()
                        .fill(Theme.accent.opacity(v))
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: reduceMotion ? 0 : -dotSize * 0.35 * max(0, sin(local * 2 * .pi)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A teardrop, point up. Inky's ink-drop motif.
struct InkyDropShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.64),
                   control1: CGPoint(x: rect.midX + w * 0.14, y: rect.minY + h * 0.22),
                   control2: CGPoint(x: rect.maxX, y: rect.minY + h * 0.4))
        p.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                   control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.86),
                   control2: CGPoint(x: rect.midX + w * 0.28, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.64),
                   control1: CGPoint(x: rect.midX - w * 0.28, y: rect.maxY),
                   control2: CGPoint(x: rect.minX, y: rect.minY + h * 0.86))
        p.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                   control1: CGPoint(x: rect.minX, y: rect.minY + h * 0.4),
                   control2: CGPoint(x: rect.midX - w * 0.14, y: rect.minY + h * 0.22))
        p.closeSubpath()
        return p
    }
}
