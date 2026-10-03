import SwiftUI

/// Inky on the page: hops between annotations, draws them, celebrates. Lives on the Inky
/// layer (page space, so it follows scroll and zoom) and never takes touches.
struct InkyPerformerView: View {
    let choreographer: InkyChoreographer
    let pageSize: CGSize
    let viewSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            if choreographer.phase != .offstage {
                TimelineView(.animation) { timeline in
                    let frame = InkyPerformerView.frame(for: choreographer, at: timeline.date)
                    stage(frame)
                }
                .transition(.opacity)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .onAppear { choreographer.hasStage = true }
        .onDisappear {
            choreographer.hasStage = false
            choreographer.finishImmediately()
        }
        .accessibilityElement(children: .contain)
    }

    private var scale: CGFloat { viewSize.width / max(pageSize.width, 1) }

    /// Inky's size on screen: about a word tall on the page, within comfortable bounds.
    private var characterSize: CGFloat { min(max(50 * scale, 38), 72) }

    private func stage(_ frame: Frame) -> some View {
        let size = characterSize
        let nib = CGPoint(x: frame.nib.x * scale, y: frame.nib.y * scale)
        let ground = CGPoint(x: frame.ground.x * scale, y: frame.ground.y * scale)
        // The figure's frame is placed so its nib tip lands on `nib`.
        let center = CGPoint(x: nib.x, y: nib.y - (InkyDrawing.nibTipInFrame.y - 0.5) * size)
        return ZStack(alignment: .topLeading) {
            Ellipse()
                .fill(InkyPalette.ink.opacity(0.13 * frame.shadow * frame.opacity))
                .frame(width: size * 0.42 * (0.6 + 0.4 * frame.shadow), height: size * 0.09)
                .position(x: ground.x, y: ground.y + 1)
            InkyCharacterView(state: frame.state, size: size)
                .scaleEffect(x: 1 / sqrt(frame.stretch), y: frame.stretch, anchor: UnitPoint(x: 0.5, y: InkyDrawing.nibTipInFrame.y))
                .scaleEffect(frame.scale, anchor: .bottom)
                .opacity(frame.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Inky")
                .accessibilityValue(choreographer.accessibilityStatus)
                .accessibilityIdentifier("inky.performer")
                .position(center)
        }
    }

    // MARK: Motion

    struct Frame: Equatable {
        /// Nib tip, page points.
        var nib: CGPoint
        /// Point on the paper under Inky (for the shadow), page points.
        var ground: CGPoint
        var state: InkyCharacterState
        var stretch: CGFloat = 1
        var scale: CGFloat = 1
        var opacity: Double = 1
        /// 1 = on the paper, smaller while airborne.
        var shadow: CGFloat = 1
    }

    /// Where Inky is and how it looks at `date`. Pure function of the choreographer's phase.
    static func frame(for c: InkyChoreographer, at date: Date) -> Frame {
        let u = c.phaseProgress(at: date)
        let elapsed = date.timeIntervalSince(c.phaseStart)
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }

        switch c.phase {
        case .offstage:
            return Frame(nib: c.to, ground: c.to, state: .idle, opacity: 0, shadow: 0)

        case .entering:
            // Falls in from above, lands with a squash.
            let fall = u * u
            let nib = lerp(c.from, c.to, fall)
            return Frame(nib: nib, ground: c.to, state: .hopping,
                         stretch: 1 + 0.12 * fall, opacity: Double(min(1, u * 3)), shadow: 0.4 + 0.6 * fall)

        case .hopping:
            // Parabolic arc; height grows with the distance.
            let eased = u * u * (3 - 2 * u)
            let ground = lerp(c.from, c.to, eased)
            let distance = hypot(c.to.x - c.from.x, c.to.y - c.from.y)
            let height = min(140, 34 + distance * 0.35)
            let arc = 4 * u * (1 - u)
            let takeoff = u < 0.12 ? sin(u / 0.12 * .pi) : 0
            return Frame(nib: CGPoint(x: ground.x, y: ground.y - height * arc), ground: ground, state: .hopping,
                         stretch: 1 + 0.14 * arc - 0.12 * takeoff, shadow: 1 - 0.55 * arc)

        case .drawing:
            let nib = c.stroke?.tip(at: u) ?? c.to
            // Landing squash during the first moment of drawing.
            let land = max(0, 1 - elapsed / 0.16)
            return Frame(nib: nib, ground: nib, state: .writing, stretch: 1 - 0.16 * CGFloat(sin(land * .pi)))

        case .celebrating:
            return Frame(nib: c.to, ground: c.to, state: .happy)

        case .leaving:
            let rise = sin(u * .pi / 2)
            return Frame(nib: lerp(c.from, c.to, rise), ground: c.from, state: .hopping,
                         stretch: 1 + 0.1 * rise, scale: 1 - 0.35 * u, opacity: Double(1 - u), shadow: 1 - u)
        }
    }
}

extension InkyChoreographer {
    /// "drawing highlight", "hopping circle", "celebrating", … (UI tests read this).
    var accessibilityStatus: String {
        [phase.rawValue, stroke.map(\.kind.rawValue)].compactMap { $0 }.joined(separator: " ")
    }
}
