import SwiftUI
import Testing
@testable import HeyInky

@MainActor
@Suite("Inky character")
struct InkyCharacterTests {
    // MARK: Snapshots

    @Test(arguments: InkyCharacterState.allCases)
    func stateSnapshot(_ state: InkyCharacterState) throws {
        let view = InkyCharacterView(state: state, size: 96, isAnimated: false).background(Color.white)
        try Snapshot.assertMatches(view, size: CGSize(width: 96, height: 96), named: "\(state)", folder: "InkyCharacter")
    }

    @Test(arguments: [20, 34, 64] as [CGFloat])
    func smallSizesSnapshot(_ size: CGFloat) throws {
        let view = HStack(spacing: 8) {
            ForEach(InkyCharacterState.allCases, id: \.self) { InkyCharacterView(state: $0, size: size, isAnimated: false) }
        }
        .padding(8)
        .background(Color.white)
        let sheet = CGSize(width: (size + 8) * CGFloat(InkyCharacterState.allCases.count) + 8, height: size + 16)
        try Snapshot.assertMatches(view, size: sheet, named: "sheet-\(Int(size))pt", folder: "InkyCharacter", scale: 2)
    }

    // MARK: Layout & motion

    @Test(arguments: [20, 26, 34, 64] as [CGFloat])
    func occupiesExactlyItsSize(_ size: CGFloat) {
        for state in InkyCharacterState.allCases {
            for animated in [true, false] {
                let controller = UIHostingController(rootView: InkyCharacterView(state: state, size: size, isAnimated: animated))
                let fitted = controller.sizeThatFits(in: CGSize(width: 500, height: 500))
                #expect(fitted == CGSize(width: size, height: size), "\(state) animated=\(animated)")
            }
        }
    }

    @Test func figureStaysInsideItsFrame() throws {
        // Sample every state over a few seconds; nothing may be drawn on the outer border.
        for state in InkyCharacterState.allCases {
            for t in stride(from: 0.0, through: 4, by: 0.37) {
                let pose = InkyMotion.pose(for: state, at: t)
                let image = try #require(Snapshot.render(InkyFigure(pose: pose, size: 64), size: CGSize(width: 64, height: 64), scale: 1, opaque: false))
                let border = Snapshot.rgba(image)!
                var touched: [String] = []
                for i in 0..<64 {
                    for (x, y) in [(i, 0), (i, 63), (0, i), (63, i)] where border.bytes[(y * 64 + x) * 4 + 3] > 40 {
                        touched.append("(\(x),\(y))")
                    }
                }
                #expect(touched.isEmpty, "\(state) at t=\(t) touches the frame edge at \(touched)")
            }
        }
    }

    @Test func statesLookDifferent() throws {
        let images = try InkyCharacterState.allCases.map { state in
            try #require(Snapshot.render(InkyFigure(pose: InkyMotion.reference(state), size: 64), size: CGSize(width: 64, height: 64)))
        }
        for i in images.indices {
            for j in images.indices where j > i {
                let (diff, _) = Snapshot.difference(images[i], images[j], threshold: 24)
                #expect(diff > 20, "\(InkyCharacterState.allCases[i]) vs \(InkyCharacterState.allCases[j])")
            }
        }
    }

    @Test func idleBlinksAndBreathes() {
        let samples = stride(from: 0.0, to: 8, by: 0.02).map { InkyMotion.idle($0) }
        #expect(samples.contains { $0.eyeOpen < 0.2 }, "blinks")
        #expect(samples.filter { $0.eyeOpen < 0.95 }.count < samples.count / 5, "eyes mostly open")
        let ys = samples.map(\.offset.y)
        #expect(ys.max()! - ys.min()! > 0.01, "bobs")
        #expect(ys.max()! - ys.min()! < 0.05, "calmly")
    }

    @Test func statesHaveTheirSignatureDetails() {
        #expect(InkyMotion.reference(.thinking).thoughtDots?.count == 3)
        #expect(InkyMotion.reference(.listening).soundWaves != nil)
        #expect(InkyMotion.reference(.happy).eyes == .happy)
        #expect(InkyMotion.reference(.writing).mouth == .tongue)
        #expect(abs(InkyMotion.reference(.writing).tilt) > 10, "leans like a held pen")
        let speaking = stride(from: 0.0, to: 2, by: 0.05).map { InkyMotion.speaking($0).mouthOpen }
        #expect(speaking.max()! - speaking.min()! > 0.4, "mouth moves while speaking")
    }

    @Test func poseMixBlendsContinuously() {
        let a = InkyMotion.reference(.idle), b = InkyMotion.reference(.writing)
        #expect(InkyPose.mix(a, b, 0) == a)
        #expect(InkyPose.mix(a, b, 1) == b)
        let mid = InkyPose.mix(a, b, 0.5)
        #expect(mid.tilt > min(a.tilt, b.tilt) && mid.tilt < max(a.tilt, b.tilt))
    }
}
