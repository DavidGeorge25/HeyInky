import Foundation
import Testing
@testable import HeyInky

@MainActor
@Suite("Inky choreography")
struct InkyChoreographyTests {
    let pageSize = CGSize(width: 816, height: 1056)

    func stroke(_ action: InkyAction) throws -> InkyStroke {
        try #require(InkyStroke(annotation: InkyAnnotation(action: action), pageSize: pageSize))
    }

    func makeChoreographer(speed: Double = 0.02, reduceMotion: Bool = false) -> InkyChoreographer {
        let c = InkyChoreographer()
        c.hasStage = true
        c.motionScale = speed
        c.reduceMotionOverride = reduceMotion
        return c
    }

    func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition(), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Nib paths

    @Test func highlightStrokeSweepsLeftToRightThroughTheMiddle() throws {
        let region = NormRect(x: 0.1, y: 0.1, width: 0.5, height: 0.04)
        let s = try stroke(.highlight(HighlightAction(region: region, color: .yellow, note: nil)))
        let rect = region.cgRect(in: pageSize)
        #expect(abs(s.start.x - rect.minX) < 5 && abs(s.end.x - rect.maxX) < 5)
        for p in stride(from: 0.0, through: 1, by: 0.1) {
            #expect(rect.insetBy(dx: -1, dy: 0).contains(s.tip(at: p)))
        }
    }

    @Test func circleStrokeGoesAllTheWayAround() throws {
        let region = NormRect(x: 0.2, y: 0.3, width: 0.3, height: 0.1)
        let s = try stroke(.circle(CircleAction(region: region, style: .solid)))
        // The pen overshoots by 8% like a real quick loop; one full turn comes back to the start.
        let fullTurn = s.tip(at: 1 / 1.08)
        #expect(hypot(s.start.x - fullTurn.x, s.start.y - fullTurn.y) < 6, "loop closes")
        let xs = stride(from: 0.0, through: 1, by: 0.05).map { s.tip(at: $0).x }
        #expect(xs.max()! - xs.min()! > s.bounds.width * 0.9, "covers the full width")
    }

    @Test func starStrokeTracesTheOutlineFromTheTop() throws {
        let s = try stroke(.star(StarAction(point: NormPoint(x: 0.5, y: 0.5))))
        #expect(abs(s.start.x - s.bounds.midX) < 0.5 && abs(s.start.y - s.bounds.minY) < 0.5)
        #expect(abs(s.end.x - s.start.x) < 0.5 && abs(s.end.y - s.start.y) < 0.5, "closed outline")
    }

    @Test func labelStrokeWritesTextThenDrawsTheArrowToTheAnchor() throws {
        let label = LabelAction(anchor: NormPoint(x: 0.4, y: 0.4), text: "Rate-limiting step", arrow: true)
        let s = try stroke(.label(label))
        let anchor = label.anchor.cgPoint(in: pageSize)
        #expect(hypot(s.end.x - anchor.x, s.end.y - anchor.y) < 0.5, "ends on the arrow tip")
        let text = InkyAnnotationGeometry.labelTextRect(label, pageSize: pageSize).cgRect(in: pageSize)
        #expect(text.insetBy(dx: -1, dy: -3).contains(s.start), "starts in the text box")
        #expect(text.insetBy(dx: -1, dy: -3).contains(s.tip(at: InkyStroke.labelTextShare - 0.01)))
    }

    @Test func fillTextStrokeStopsWhereTheWritingEnds() throws {
        let region = NormRect(x: 0.1, y: 0.6, width: 0.8, height: 0.04)
        let s = try stroke(.fillText(FillTextAction(region: region, text: "x = 4", handwritingStyle: true)))
        #expect(s.end.x < region.cgRect(in: pageSize).midX, "short text in a wide box")
        #expect(s.end.x > s.start.x)
    }

    @Test func repliesAreNotDrawn() {
        #expect(InkyStroke(annotation: InkyAnnotation(action: .say(SayAction(text: "hi"))), pageSize: pageSize) == nil)
    }

    // MARK: Sequence

    @Test func hopsToEachAnnotationDrawsItThenCelebratesAndLeaves() async {
        let c = makeChoreographer()
        let a = InkyAnnotation(action: .highlight(HighlightAction(region: NormRect(x: 0.1, y: 0.1, width: 0.4, height: 0.04), color: .yellow, note: nil)))
        let b = InkyAnnotation(action: .circle(CircleAction(region: NormRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1), style: .solid)))
        c.perform(a, pageSize: pageSize)
        c.perform(b, pageSize: pageSize)
        #expect(c.isPending(a.id) && c.isPending(b.id), "hidden until Inky draws them")

        var replied = false
        c.afterPerformance { replied = true }
        #expect(!replied, "reply waits for the drawing")

        await waitUntil { !c.isOnStage }
        #expect(c.history == ["entering highlight", "drawing highlight", "hopping circle", "drawing circle", "celebrating", "leaving", "offstage"])
        #expect(replied)
        #expect(!c.isPending(a.id) && !c.isPending(b.id))
    }

    @Test func annotationAppearsOnlyWhenInkyArrives() async throws {
        let c = makeChoreographer(speed: 40)
        let a = InkyAnnotation(action: .star(StarAction(point: NormPoint(x: 0.3, y: 0.3))))
        c.perform(a, pageSize: pageSize)
        await waitUntil { c.phase == .entering }
        #expect(c.isPending(a.id))
        #expect(!c.isDrawing(a.id))

        // On landing, the nib is exactly at the stroke's start.
        let s = try stroke(a.action)
        let landed = InkyPerformerView.frame(for: c, at: c.phaseStart.addingTimeInterval(c.phaseDuration))
        #expect(hypot(landed.nib.x - s.start.x, landed.nib.y - s.start.y) < 0.5)
        let falling = InkyPerformerView.frame(for: c, at: c.phaseStart.addingTimeInterval(c.phaseDuration * 0.3))
        #expect(falling.nib.y < s.start.y, "drops in from above")

        c.finishImmediately()
        #expect(!c.isPending(a.id))
        #expect(c.phase == .offstage)
    }

    @Test func hopArcsAboveTheGround() async {
        let c = makeChoreographer(speed: 0.2)
        let a = InkyAnnotation(action: .star(StarAction(point: NormPoint(x: 0.2, y: 0.2))))
        let b = InkyAnnotation(action: .star(StarAction(point: NormPoint(x: 0.8, y: 0.2))))
        c.perform(a, pageSize: pageSize)
        c.perform(b, pageSize: pageSize)
        await waitUntil { c.phase == .hopping }
        #expect(c.phase == .hopping)
        let mid = InkyPerformerView.frame(for: c, at: c.phaseStart.addingTimeInterval(c.phaseDuration / 2))
        #expect(mid.state == .hopping)
        #expect(mid.nib.y < mid.ground.y - 30, "in the air")
        #expect(mid.shadow < 1)
        c.finishImmediately()
    }

    @Test func reduceMotionFadesInWithoutHopping() async {
        let c = makeChoreographer(reduceMotion: true)
        let a = InkyAnnotation(action: .star(StarAction(point: NormPoint(x: 0.3, y: 0.3))))
        let b = InkyAnnotation(action: .star(StarAction(point: NormPoint(x: 0.6, y: 0.3))))
        c.perform(a, pageSize: pageSize)
        c.perform(b, pageSize: pageSize)
        await waitUntil { !c.isOnStage && c.pendingIDs.isEmpty }
        #expect(c.pendingIDs.isEmpty)
        #expect(!c.history.contains { $0.hasPrefix("hopping") || $0.hasPrefix("drawing") || $0.hasPrefix("entering") })
    }

    @Test func withoutAStageAnnotationsAppearImmediately() {
        let c = InkyChoreographer()
        let a = InkyAnnotation(action: .star(StarAction(point: NormPoint(x: 0.3, y: 0.3))))
        c.perform(a, pageSize: pageSize)
        #expect(!c.isPending(a.id))
        var replied = false
        c.afterPerformance { replied = true }
        #expect(replied)
    }

    // MARK: Feedback

    @Test func soundsAreShortAndQuiet() {
        for cue in InkyFeedback.Cue.allCases {
            let samples = InkySounds.samples(for: cue)
            #expect(Double(samples.count) / InkySounds.sampleRate < 0.5, "\(cue) is short")
            #expect(samples.map(abs).max()! < 0.3, "\(cue) is quiet")
            #expect(samples.map(abs).max()! > 0.02, "\(cue) is audible")
            let wav = InkySounds.wav(samples)
            #expect(wav.prefix(4) == Data("RIFF".utf8))
            #expect(wav.count == 44 + samples.count * 2)
        }
    }
}
