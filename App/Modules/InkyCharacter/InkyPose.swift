import CoreGraphics
import Foundation

/// Everything that changes when Inky moves, as plain numbers. `InkyFigure` draws a pose;
/// `InkyMotion` turns (state, time) into a pose. Keeping motion a pure function of time
/// makes every frame reproducible (snapshot tests render fixed times).
///
/// Units are fractions of the character's frame (0…1), angles in degrees.
struct InkyPose: Equatable, Sendable {
    enum Eyes: Equatable, Sendable {
        case open
        /// Closed, smiling arcs (^ ^).
        case happy
    }

    enum Mouth: Equatable, Sendable {
        case smile
        /// Open, talking or delighted. Amount 0…1.
        case open
        /// Small "o", curious or concentrating.
        case round
        /// Tiny tongue poking out of a smile: concentrating while writing.
        case tongue
    }

    /// Whole-body translation.
    var offset = CGPoint.zero
    /// Tilt around the nib tip.
    var tilt: Double = 0
    /// Vertical stretch around the nib tip (1 = rest, < 1 squashed, > 1 stretched).
    var stretch: CGFloat = 1
    var eyes: Eyes = .open
    /// 1 = open, 0 = closed (blink).
    var eyeOpen: CGFloat = 1
    /// Eye size multiplier (wide-eyed when listening or hopping).
    var eyeScale: CGFloat = 1
    /// Where the pupils look, -1…1 on each axis.
    var gaze = CGPoint.zero
    var mouth: Mouth = .smile
    var mouthOpen: CGFloat = 0
    /// The ink drop on Inky's head: offset and sway (it lags behind the body like an ear).
    var dropOffset = CGPoint.zero
    var dropTilt: Double = 0
    /// Thinking dots, each 0…1 visibility (nil = hidden).
    var thoughtDots: [CGFloat]?
    /// Listening sound arcs, 0…1 phase (nil = hidden).
    var soundWaves: CGFloat?
    /// Happy ink splashes, 0…1 phase (nil = hidden).
    var splash: CGFloat?
    var opacity: Double = 1

    static let rest = InkyPose()

    /// Blends two poses. Discrete parts switch halfway through.
    static func mix(_ a: InkyPose, _ b: InkyPose, _ t: CGFloat) -> InkyPose {
        if t <= 0 { return a }
        if t >= 1 { return b }
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        func ld(_ x: Double, _ y: Double) -> Double { x + (y - x) * Double(t) }
        func lp(_ x: CGPoint, _ y: CGPoint) -> CGPoint { CGPoint(x: l(x.x, y.x), y: l(x.y, y.y)) }
        var p = t < 0.5 ? a : b
        p.offset = lp(a.offset, b.offset)
        p.tilt = ld(a.tilt, b.tilt)
        p.stretch = l(a.stretch, b.stretch)
        p.eyeOpen = l(a.eyeOpen, b.eyeOpen)
        p.eyeScale = l(a.eyeScale, b.eyeScale)
        p.gaze = lp(a.gaze, b.gaze)
        p.mouthOpen = l(a.mouthOpen, b.mouthOpen)
        p.dropOffset = lp(a.dropOffset, b.dropOffset)
        p.dropTilt = ld(a.dropTilt, b.dropTilt)
        p.opacity = ld(a.opacity, b.opacity)
        return p
    }
}

/// Per-state motion. All functions are periodic in `time` (seconds).
enum InkyMotion {
    /// A time that shows each state's characteristic expression (eyes open, mid-gesture).
    /// Used for Reduce Motion and snapshot tests.
    static let referenceTime: TimeInterval = 0.62

    static func pose(for state: InkyCharacterState, at time: TimeInterval) -> InkyPose {
        switch state {
        case .idle: idle(time)
        case .listening: listening(time)
        case .thinking: thinking(time)
        case .speaking: speaking(time)
        case .happy: happy(time)
        case .hopping: hopping(time)
        case .writing: writing(time)
        }
    }

    static func reference(_ state: InkyCharacterState) -> InkyPose {
        pose(for: state, at: referenceTime)
    }

    // MARK: States

    static func idle(_ t: TimeInterval) -> InkyPose {
        var p = InkyPose()
        let breath = sin(t * 2 * .pi / 2.6)
        p.offset.y = CGFloat(breath) * 0.014
        p.stretch = 1 + CGFloat(breath) * 0.012
        p.tilt = -3 + sin(t * 2 * .pi / 5.2) * 1.5
        p.eyeOpen = blink(t)
        // Slow look-around: glance left, center, right, center.
        let look = sin(t * 2 * .pi / 9)
        p.gaze = CGPoint(x: CGFloat(smoothStep(look)) * 0.6, y: 0.05)
        p.dropTilt = sin(t * 2 * .pi / 2.6 - 0.8) * 6
        return p
    }

    static func listening(_ t: TimeInterval) -> InkyPose {
        var p = InkyPose()
        let nod = sin(t * 2 * .pi / 1.4)
        p.offset.y = CGFloat(nod) * 0.01
        p.tilt = 5 + nod * 1.5
        p.eyeScale = 1.12
        p.eyeOpen = blink(t + 1.3)
        p.gaze = CGPoint(x: -0.15, y: -0.1)
        p.mouth = .round
        p.mouthOpen = 0.35
        // The drop perks up and wiggles like an ear.
        p.dropOffset = CGPoint(x: 0, y: -0.015)
        p.dropTilt = sin(t * 2 * .pi * 2.4) * 11
        p.soundWaves = CGFloat((t / 1.1).truncatingRemainder(dividingBy: 1))
        return p
    }

    static func thinking(_ t: TimeInterval) -> InkyPose {
        var p = InkyPose()
        let sway = sin(t * 2 * .pi / 2.2)
        p.tilt = sway * 7
        p.offset.y = CGFloat(abs(sway)) * -0.008
        p.eyeOpen = blink(t + 2.1)
        p.gaze = CGPoint(x: 0.65, y: -0.7)
        p.mouth = .round
        p.mouthOpen = 0.15
        p.dropTilt = -sway * 9
        let period = 1.2
        let phase = (t / period).truncatingRemainder(dividingBy: 1)
        p.thoughtDots = (0..<3).map { i in
            let local = phase - Double(i) * 0.18
            return CGFloat(0.35 + 0.65 * max(0, sin(local * 2 * .pi)))
        }
        return p
    }

    static func speaking(_ t: TimeInterval) -> InkyPose {
        var p = InkyPose()
        let bob = sin(t * 2 * .pi / 1.8)
        p.offset.y = CGFloat(bob) * 0.012
        p.tilt = -2 + bob * 2
        p.eyeOpen = blink(t + 0.7)
        p.gaze = CGPoint(x: 0.1, y: 0)
        p.mouth = .open
        // Syllable-like rhythm: two overlapping frequencies.
        let talk = abs(sin(t * 2 * .pi * 2.3)) * 0.7 + abs(sin(t * 2 * .pi * 3.7)) * 0.3
        p.mouthOpen = CGFloat(0.25 + 0.75 * talk)
        p.dropTilt = sin(t * 2 * .pi / 1.8 - 0.9) * 7
        return p
    }

    static func happy(_ t: TimeInterval) -> InkyPose {
        var p = InkyPose()
        let period = 0.9
        let u = (t / period).truncatingRemainder(dividingBy: 1)
        // A little bounce: up in the air for the first 60%, then squash on landing.
        let air = u < 0.6 ? sin(u / 0.6 * .pi) : 0
        let squash = u >= 0.6 ? sin((u - 0.6) / 0.4 * .pi) : 0
        p.offset.y = -CGFloat(air) * 0.045
        p.stretch = 1 + CGFloat(air) * 0.03 - CGFloat(squash) * 0.08
        p.tilt = sin(t * 2 * .pi / (period * 2)) * 5
        p.eyes = .happy
        p.mouth = .open
        p.mouthOpen = 0.8
        // The drop lags behind the jump.
        p.dropOffset = CGPoint(x: 0, y: CGFloat(air) * 0.035)
        p.dropTilt = sin(t * 2 * .pi / period) * 10
        p.splash = CGFloat(u)
        return p
    }

    static func hopping(_ t: TimeInterval) -> InkyPose {
        var p = InkyPose()
        p.eyeScale = 1.1
        p.gaze = CGPoint(x: 0.3, y: 0.2)
        p.mouth = .round
        p.mouthOpen = 0.55
        p.dropOffset = CGPoint(x: 0, y: 0.02)
        p.dropTilt = sin(t * 2 * .pi * 1.8) * 12
        return p
    }

    static func writing(_ t: TimeInterval) -> InkyPose {
        var p = InkyPose()
        // Held like a pen: leaning, with a quick scribbling wobble around the nib.
        let scribble = sin(t * 2 * .pi * 7) * 0.6 + sin(t * 2 * .pi * 11.3) * 0.4
        p.tilt = -16 + scribble * 4
        p.offset.y = CGFloat(abs(scribble)) * -0.006
        p.eyeOpen = 0.85
        p.gaze = CGPoint(x: -0.2, y: 0.85)
        p.mouth = .tongue
        p.dropTilt = scribble * 10
        return p
    }

    // MARK: Helpers

    /// Blinks every ~3.8 s, double-blinking every other time.
    static func blink(_ t: TimeInterval) -> CGFloat {
        let period = 3.8
        let cycle = t.truncatingRemainder(dividingBy: period * 2)
        let local = cycle.truncatingRemainder(dividingBy: period)
        let length = 0.16
        func closed(_ start: Double) -> Double {
            let x = (local - start) / length
            guard x >= 0, x <= 1 else { return 0 }
            return sin(x * .pi)
        }
        var shut = closed(period - 0.4)
        if cycle >= period { shut = max(shut, closed(period - 0.75)) }
        return CGFloat(1 - shut)
    }

    /// Ease a -1…1 sine so the gaze holds at the extremes instead of drifting constantly.
    static func smoothStep(_ x: Double) -> Double {
        let s = max(-1, min(1, x * 1.6))
        return s * (1.5 - 0.5 * s * s)
    }
}
