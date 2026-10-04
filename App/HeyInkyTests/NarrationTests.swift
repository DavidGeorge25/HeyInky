import Testing
import UIKit
@testable import HeyInky

@MainActor
@Suite("Narrated teaching")
struct NarrationTests {
    @Test func inkySaysEachLineWhileDrawingItsMark() async throws {
        let choreographer = InkyChoreographer()
        choreographer.hasStage = true
        choreographer.reduceMotionOverride = false
        choreographer.motionScale = 0.05
        var spoken: [String] = []
        var finishedBeforeNext = true
        choreographer.narrator = { text in
            spoken.append(text)
            try? await Task.sleep(for: .milliseconds(120))
            if choreographer.isDrawing(UUID()) { finishedBeforeNext = false }
        }
        let pageSize = CGSize(width: 816, height: 1056)
        let first = InkyAnnotation(action: .star(StarAction(point: NormPoint(x: 0.2, y: 0.2))))
        let second = InkyAnnotation(action: .star(StarAction(point: NormPoint(x: 0.6, y: 0.6))))
        choreographer.perform(first, pageSize: pageSize, narration: "First, the star on the left.")
        choreographer.perform(second, pageSize: pageSize, narration: "Then the one on the right.")
        var waited = 0
        while choreographer.isOnStage && waited < 100 { try await Task.sleep(for: .milliseconds(50)); waited += 1 }
        #expect(spoken == ["First, the star on the left.", "Then the one on the right."])
        #expect(finishedBeforeNext)
    }

    @Test func voiceFlagReachesThePrompt() {
        var request = Fixtures.sampleRequest()
        request.narrate = true
        #expect(InkyPromptBuilder.userText(for: request).contains("Voice: ON"))
    }
}
