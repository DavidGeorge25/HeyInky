import Foundation
import Observation
import SwiftUI
import UIKit

/// Plays Inky acting on the page: for each new annotation Inky hops to where it goes,
/// draws it (the annotation is revealed under the nib), then does a happy bounce when the
/// queue is empty and hops away. One per page (`PageEditorModel.choreographer`).
///
/// Timing lives here; the views (`InkyPerformerView`, `InkyRevealingAnnotationView`) read
/// `phase`, `phaseStart` and `phaseDuration` inside a `TimelineView` and interpolate.
/// With Reduce Motion, annotations simply fade in one after another.
@MainActor
@Observable
final class InkyChoreographer {
    enum Phase: String, Equatable, Sendable {
        case offstage
        /// Dropping onto the page at the first annotation.
        case entering
        case hopping
        case drawing
        case celebrating
        case leaving
    }

    private(set) var phase: Phase = .offstage
    private(set) var phaseStart = Date.distantPast
    /// Seconds, already scaled by `motionScale`.
    private(set) var phaseDuration: TimeInterval = 0
    /// Nib position (page points) at the start and end of the current phase.
    private(set) var from = CGPoint.zero
    private(set) var to = CGPoint.zero
    /// The annotation being hopped to or drawn.
    private(set) var stroke: InkyStroke?
    /// Annotations added but not drawn yet; the layer hides them.
    private(set) var pendingIDs: Set<UUID> = []
    /// Recent phases ("hopping highlight", "drawing highlight", "celebrating", …) for tests and debugging.
    @ObservationIgnored private(set) var history: [String] = []

    /// Set by the Inky layer while it is on screen. Without a stage (e.g. headless tests)
    /// annotations appear immediately.
    var hasStage = false
    /// Multiplies every duration. `-InkyMotionScale 3` slows Inky down (UI tests, recordings).
    var motionScale: Double = {
        let value = UserDefaults.standard.double(forKey: "InkyMotionScale")
        return value > 0 ? value : 1
    }()
    /// nil = follow the system setting.
    var reduceMotionOverride: Bool?

    /// Where Inky goes home after a performance (the floating button), in page points; nil =
    /// fade out where the last annotation was. Read when Inky leaves, so it follows scroll/zoom.
    @ObservationIgnored var homeLocator: (@MainActor () -> CGPoint?)?
    /// Speaks a narration line and returns when it has been said (set by the session).
    @ObservationIgnored var narrator: (@MainActor (String) async -> Void)?

    @ObservationIgnored private var queue: [InkyStroke] = []
    @ObservationIgnored private var afterPerformance: [@MainActor () -> Void] = []
    @ObservationIgnored private var driver: Task<Void, Never>?

    var reduceMotion: Bool { reduceMotionOverride ?? UIAccessibility.isReduceMotionEnabled }
    var isOnStage: Bool { phase != .offstage || !queue.isEmpty }

    func isPending(_ id: UUID) -> Bool { pendingIDs.contains(id) }

    func isDrawing(_ id: UUID) -> Bool { phase == .drawing && stroke?.annotationID == id }

    /// 0…1 through the current phase.
    func phaseProgress(at date: Date) -> CGFloat {
        guard phaseDuration > 0 else { return 1 }
        return CGFloat(min(max(date.timeIntervalSince(phaseStart) / phaseDuration, 0), 1))
    }

    /// Reveal progress of the annotation being drawn.
    func drawProgress(at date: Date) -> CGFloat {
        phase == .drawing ? phaseProgress(at: date) : 1
    }

    // MARK: Queue

    /// Queues an annotation that was just added to the page.
    func perform(_ annotation: InkyAnnotation, pageSize: CGSize, narration: String? = nil) {
        guard hasStage, var stroke = InkyStroke(annotation: annotation, pageSize: pageSize) else {
            // Nothing to draw on stage: still say it.
            if let narration, let narrator { Task { await narrator(narration) } }
            return
        }
        stroke.narration = narration
        pendingIDs.insert(stroke.annotationID)
        queue.append(stroke)
        if driver == nil {
            driver = Task { [weak self] in
                await self?.run()
                self?.driver = nil
            }
        }
    }

    /// Runs `action` once Inky has finished drawing everything queued (right away if idle).
    /// Used to hold Inky's reply toast until the drawing is done.
    func afterPerformance(_ action: @escaping @MainActor () -> Void) {
        if isOnStage { afterPerformance.append(action) } else { action() }
    }

    /// Skips the rest of the performance: everything queued appears at once.
    func finishImmediately() {
        driver?.cancel()
        driver = nil
        queue.removeAll()
        pendingIDs.removeAll()
        stroke = nil
        set(.offstage, from: to, to: to, duration: 0)
        flushAfterPerformance()
    }

    // MARK: Performance

    private func run() async {
        while !queue.isEmpty {
            if reduceMotion {
                await fadeInQueued()
            } else {
                await drawQueued()
            }
            guard !Task.isCancelled else { return }
            if !queue.isEmpty { continue }

            flushAfterPerformance()
            if reduceMotion {
                set(.offstage, from: to, to: to, duration: 0)
                InkyFeedback.play(.done)
                continue
            }
            InkyFeedback.play(.done)
            guard await play(.celebrating, from: to, to: to, duration: 0.95) else { return }
            if !queue.isEmpty { continue }
            if let home = homeLocator?(), hypot(home.x - to.x, home.y - to.y) > 1 {
                // Hop back to the floating button and slip into it.
                let distance = hypot(home.x - to.x, home.y - to.y)
                guard await play(.hopping, from: to, to: home, duration: 0.4 + min(0.3, Double(distance) / 1600)) else { return }
                if !queue.isEmpty { continue }
                guard await play(.leaving, from: home, to: home, duration: 0.25) else { return }
            } else {
                guard await play(.leaving, from: to, to: CGPoint(x: to.x, y: to.y - 50), duration: 0.4) else { return }
            }
            if !queue.isEmpty { continue }
            set(.offstage, from: to, to: to, duration: 0)
        }
    }

    private func drawQueued() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            stroke = next
            let target = next.start
            let arrived: Bool
            if phase == .offstage || phase == .leaving {
                arrived = await play(.entering, from: CGPoint(x: target.x, y: target.y - 110), to: target, duration: 0.5)
            } else {
                let distance = hypot(target.x - to.x, target.y - to.y)
                arrived = await play(.hopping, from: to, to: target, duration: 0.36 + min(0.3, Double(distance) / 1600))
            }
            guard arrived else { return }
            InkyFeedback.play(.land)
            pendingIDs.remove(next.annotationID)
            // Talk while drawing; move on once both are done.
            let speech: Task<Void, Never>? = next.narration.flatMap { text in narrator.map { say in Task { @MainActor in await say(text) } } }
            guard await play(.drawing, from: target, to: next.end, duration: next.duration) else { speech?.cancel(); return }
            await speech?.value
            stroke = nil
        }
    }

    private func fadeInQueued() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            _ = withAnimation(.easeOut(duration: 0.3)) {
                pendingIDs.remove(next.annotationID)
            }
            InkyFeedback.play(.land)
            if let text = next.narration, let narrator { await narrator(text) }
            try? await Task.sleep(for: .seconds(0.15 * motionScale))
            if Task.isCancelled { return }
        }
    }

    /// Enters a phase and waits for it to finish. Returns false if cancelled.
    private func play(_ phase: Phase, from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool {
        set(phase, from: from, to: to, duration: duration * motionScale)
        try? await Task.sleep(for: .seconds(phaseDuration))
        return !Task.isCancelled
    }

    private func set(_ phase: Phase, from: CGPoint, to: CGPoint, duration: TimeInterval) {
        self.from = from
        self.to = to
        phaseDuration = duration
        phaseStart = .now
        self.phase = phase
        let entry = [phase.rawValue, stroke.map(\.kind.rawValue)].compactMap { $0 }.joined(separator: " ")
        history.append(entry)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }

    private func flushAfterPerformance() {
        let actions = afterPerformance
        afterPerformance.removeAll()
        actions.forEach { $0() }
    }
}
