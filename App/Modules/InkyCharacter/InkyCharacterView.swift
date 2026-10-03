import SwiftUI

/// What Inky is doing; drives the character's pose and animation.
enum InkyCharacterState: Equatable, Sendable, CaseIterable {
    case idle
    /// Mic is on: wide eyes, ink-drop "ear" wiggle, sound arcs.
    case listening
    /// Waiting for the model: looks up, sways, thought dots.
    case thinking
    /// Reading an explanation aloud: talking mouth.
    case speaking
    /// Done: happy eyes, bounce, ink splashes.
    case happy
    /// In the air between two spots on the page.
    case hopping
    /// Drawing an annotation: leaning like a held pen, scribbling, tongue out.
    case writing
}

/// Inky, the pen character. Always exactly `size × size`; reads from 20 to 64 pt and up.
///
/// Motion is a pure function of time (`InkyMotion`), rendered with a `TimelineView`.
/// State changes blend over a quarter second. With Reduce Motion (or `isAnimated: false`)
/// Inky holds each state's reference pose and state changes cross-fade.
struct InkyCharacterView: View {
    var state: InkyCharacterState = .idle
    var size: CGFloat = 32
    var isAnimated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previous: InkyCharacterState?
    @State private var changedAt = Date.distantPast

    static let blendDuration: TimeInterval = 0.25

    var body: some View {
        Group {
            if isAnimated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 40)) { timeline in
                    InkyFigure(pose: pose(at: timeline.date), size: size)
                }
            } else {
                InkyFigure(pose: InkyMotion.reference(state), size: size)
                    .id(state)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(isAnimated && !reduceMotion ? nil : .easeInOut(duration: 0.25), value: state)
        .onChange(of: state) { old, _ in
            previous = old
            changedAt = .now
        }
        .accessibilityHidden(true)
    }

    private func pose(at date: Date) -> InkyPose {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
        let current = InkyMotion.pose(for: state, at: t)
        let blend = date.timeIntervalSince(changedAt) / Self.blendDuration
        guard let previous, blend < 1 else { return current }
        let eased = blend * blend * (3 - 2 * blend)
        return InkyPose.mix(InkyMotion.pose(for: previous, at: t), current, CGFloat(eased))
    }
}

#Preview("States") {
    VStack(spacing: 28) {
        HStack(spacing: 28) {
            ForEach(InkyCharacterState.allCases, id: \.self) { state in
                VStack {
                    InkyCharacterView(state: state, size: 64)
                    Text(String(describing: state)).font(.caption)
                }
            }
        }
        HStack(spacing: 20) {
            ForEach([20, 26, 34, 48, 64] as [CGFloat], id: \.self) { size in
                InkyCharacterView(state: .idle, size: size)
            }
        }
    }
    .padding(40)
}
