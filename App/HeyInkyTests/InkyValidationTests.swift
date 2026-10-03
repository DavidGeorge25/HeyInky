import Foundation
import Testing
import UIKit
@testable import HeyInky

@Suite("Response validation")
struct InkyResponseValidatorTests {
    struct Case: Decodable {
        var name: String
        var valid: Bool
        var problem: String?
        var action: InkyAction
    }

    static func sharedCases() throws -> [Case] {
        let bundle = Bundle(for: ScriptedClientToken.self)
        let url = try #require(bundle.url(forResource: "cases", withExtension: "json", subdirectory: "fixtures/validation"))
        struct File: Decodable { var cases: [Case] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }

    /// Same fixtures as evals/inky_eval/validate.py, so the two validators can't drift.
    @Test func sharedFixturesMatch() throws {
        let cases = try Self.sharedCases()
        #expect(cases.count >= 20)
        for c in cases {
            switch InkyResponseValidator.check(c.action) {
            case .valid:
                #expect(c.valid, "\(c.name) should be invalid")
            case .invalid(let message):
                #expect(!c.valid, "\(c.name) should be valid: \(message)")
                if let problem = c.problem {
                    #expect(message.contains(problem), "\(c.name): '\(message)' lacks '\(problem)'")
                }
            }
        }
    }

    @Test func clampsSmallEdgeOverflow() {
        let action = InkyAction.highlight(HighlightAction(region: NormRect(x: 0.5, y: 0.9, width: 0.51, height: 0.11), color: .yellow, note: nil))
        guard case .valid(.highlight(let h)) = InkyResponseValidator.check(action) else { Issue.record("expected valid"); return }
        #expect(h.region.maxX <= 1 && h.region.maxY <= 1)
    }

    @Test func unknownRemovalIDsAreProblems() {
        var request = Fixtures.sampleRequest()
        request.pageAnnotations = [Fixtures.mark()]
        #expect(InkyResponseValidator.responseProblems(InkyResponse(removeAnnotations: ["m1"], actions: []), request: request).isEmpty)
        #expect(!InkyResponseValidator.responseProblems(InkyResponse(removeAnnotations: ["m4"], actions: []), request: request).isEmpty)
        #expect(!InkyResponseValidator.responseProblems(InkyResponse(actions: []), request: request).isEmpty)
    }

    @Test func shortIDsResolve() {
        var request = Fixtures.sampleRequest()
        let a = Fixtures.mark(), b = Fixtures.mark()
        request.pageAnnotations = [a, b]
        #expect(request.annotationID(forShortID: "m2") == b.id)
        #expect(request.annotationID(forShortID: "M1") == a.id)
        #expect(request.annotationID(forShortID: "2") == b.id)
        #expect(request.annotationID(forShortID: b.id.uuidString) == b.id)
        #expect(request.annotationID(forShortID: "m3") == nil)
        #expect(request.shortID(for: b.id) == "m2")
    }
}

final class ScriptedClientToken {}

/// Plays back one scripted attempt per call and records the requests it saw.
final class ScriptedClient: InkyModelClient, @unchecked Sendable {
    enum Step { case events([InkyStreamEvent]), fail(InkyClientError) }
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [InkyRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func respond(to request: InkyRequest) -> AsyncThrowingStream<InkyStreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let step = steps.isEmpty ? .fail(.invalidResponse("no more steps")) : steps.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            switch step {
            case .events(let events):
                for e in events { continuation.yield(e) }
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    /// Streams actions one by one then completes, like the proxy client.
    static func answer(_ actions: [InkyAction], remove: [String] = []) -> Step {
        .events(actions.map { .action($0) } + [.completed(InkyResponse(removeAnnotations: remove, actions: actions))])
    }
}

@Suite("Validating client (retry)")
struct ValidatingInkyModelClientTests {
    static let say = InkyAction.say(SayAction(text: "Highlighted it."))
    static let good = InkyAction.highlight(HighlightAction(region: NormRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05), color: .yellow, note: nil))
    static let bad = InkyAction.highlight(HighlightAction(region: NormRect(x: 0.8, y: 0.1, width: 0.6, height: 0.05), color: .yellow, note: nil))

    func collect(_ client: any InkyModelClient, _ request: InkyRequest = Fixtures.sampleRequest()) async throws -> (streamed: [InkyAction], completed: InkyResponse?) {
        var streamed: [InkyAction] = []
        var completed: InkyResponse?
        for try await event in client.respond(to: request) {
            switch event {
            case .action(let a): streamed.append(a)
            case .completed(let r): completed = r
            case .textDelta: break
            }
        }
        return (streamed, completed)
    }

    @Test func validAnswerPassesThroughWithoutRetry() async throws {
        let base = ScriptedClient([ScriptedClient.answer([Self.say, Self.good])])
        let (streamed, completed) = try await collect(ValidatingInkyModelClient(base: base))
        #expect(streamed == [Self.say, Self.good])
        #expect(completed?.actions == streamed)
        #expect(base.requests.count == 1)
        #expect(base.requests[0].correction == nil)
    }

    @Test func invalidActionTriggersOneRetryWithFeedback() async throws {
        let fixed = InkyAction.highlight(HighlightAction(region: NormRect(x: 0.6, y: 0.1, width: 0.38, height: 0.05), color: .yellow, note: nil))
        let base = ScriptedClient([
            ScriptedClient.answer([Self.say, Self.bad]),
            ScriptedClient.answer([Self.say, fixed]),  // repeats the say; must not be shown twice
        ])
        let (streamed, completed) = try await collect(ValidatingInkyModelClient(base: base))
        #expect(streamed == [Self.say, fixed])
        #expect(completed?.actions == streamed)
        #expect(base.requests.count == 2)
        let correction = try #require(base.requests[1].correction)
        #expect(correction.problems.first?.contains("outside the page") == true)
        #expect(correction.alreadyApplied == [Self.say])
        let text = InkyPromptBuilder.questionText(for: base.requests[1])
        #expect(text.contains("rejected"))
        #expect(text.contains("do not repeat them"))
    }

    @Test func malformedJSONIsRetried() async throws {
        let base = ScriptedClient([.fail(.invalidResponse("bad json")), ScriptedClient.answer([Self.say])])
        let (streamed, _) = try await collect(ValidatingInkyModelClient(base: base))
        #expect(streamed == [Self.say])
        #expect(base.requests[1].correction?.problems.first?.contains("not valid JSON") == true)
    }

    @Test func givesUpAfterOneRetry() async {
        let base = ScriptedClient([ScriptedClient.answer([Self.bad]), ScriptedClient.answer([Self.bad]), ScriptedClient.answer([Self.good])])
        do {
            _ = try await collect(ValidatingInkyModelClient(base: base))
            Issue.record("expected failure")
        } catch {
            #expect(error is InkyClientError)
        }
        #expect(base.requests.count == 2)
    }

    @Test func keepsPartialAnswerWhenRetryAlsoFails() async throws {
        let base = ScriptedClient([ScriptedClient.answer([Self.say, Self.bad]), .fail(.invalidResponse("still bad"))])
        let (streamed, completed) = try await collect(ValidatingInkyModelClient(base: base))
        #expect(streamed == [Self.say])
        #expect(completed?.actions == [Self.say])
    }

    @Test func networkErrorsAreNotRetried() async {
        let base = ScriptedClient([.fail(.network("offline")), ScriptedClient.answer([Self.say])])
        do {
            _ = try await collect(ValidatingInkyModelClient(base: base))
            Issue.record("expected failure")
        } catch let error as InkyClientError {
            #expect(error == .network("offline"))
        } catch {
            Issue.record("\(error)")
        }
        #expect(base.requests.count == 1)
    }

    @Test func removalShortIDsBecomeAnnotationUUIDs() async throws {
        var request = Fixtures.sampleRequest(question: "undo that")
        let a = Fixtures.mark(), b = Fixtures.mark()
        request.pageAnnotations = [a, b]
        let base = ScriptedClient([ScriptedClient.answer([.say(SayAction(text: "Removed it."))], remove: ["m2"])])
        let (_, completed) = try await collect(ValidatingInkyModelClient(base: base), request)
        #expect(completed?.removedAnnotationIDs == [b.id])
    }

    @Test func unknownRemovalIDIsRetried() async throws {
        var request = Fixtures.sampleRequest(question: "undo that")
        let a = Fixtures.mark()
        request.pageAnnotations = [a]
        let base = ScriptedClient([
            ScriptedClient.answer([.say(SayAction(text: "Removed."))], remove: ["m7"]),
            ScriptedClient.answer([], remove: ["m1"]),
        ])
        let (_, completed) = try await collect(ValidatingInkyModelClient(base: base), request)
        #expect(completed?.removedAnnotationIDs == [a.id])
        #expect(base.requests.count == 2)
    }

    @Test func factoryWrapsClients() {
        #expect(InkyClientFactory.makeDefault() is ValidatingInkyModelClient)
    }
}

@Suite("Context packet")
struct InkyContextPacketTests {
    @Test func userTextListsMarksAndHistory() {
        var request = Fixtures.sampleRequest(question: "now explain why")
        let mark = Fixtures.mark()
        request.pageAnnotations = [mark]
        request.history = [InkyTurn(question: "highlight the title", actions: [.say(SayAction(text: "Done.")), mark.action], createdAnnotationIDs: [mark.id])]
        let text = InkyPromptBuilder.userText(for: request)
        #expect(text.contains("m1: yellow highlight"))
        #expect(text.contains("made for \"highlight the title\""))
        #expect(text.contains("1. Student: \"highlight the title\""))
        #expect(text.contains("said \"Done.\""))
        #expect(text.contains("Marks from that turn still on the page: m1"))
    }

    @Test func emptyContextSaysNone() {
        let text = InkyPromptBuilder.userText(for: Fixtures.sampleRequest())
        #expect(text.contains("Inky marks already on the page: none."))
        #expect(!text.contains("Earlier in this conversation"))
    }

    @Test func schemaRequiresRemoveAnnotationsBeforeActions() throws {
        let schemaText = InkyPromptBuilder.actionSchemaText()
        let remove = try #require(schemaText.range(of: "\"removeAnnotations\": {"))
        let actions = try #require(schemaText.range(of: "\"actions\": {"))
        #expect(remove.lowerBound < actions.lowerBound)
    }

    @Test func responseDecodesWithAndWithoutRemovals() throws {
        let old = try JSONDecoder().decode(InkyResponse.self, from: Data(#"{"actions":[{"type":"say","text":"hi"}]}"#.utf8))
        #expect(old.removeAnnotations.isEmpty)
        let undo = try Fixtures.response("undo_last")
        #expect(undo.removeAnnotations == ["m2", "m3"])
        var scanner = IncrementalActionScanner()
        #expect(scanner.feed(#"{"removeAnnotations":["m1"],"actions":[{"type":"say","text":"x"}]}"#).count == 1)
    }

    @MainActor
    @Test func marksAreDrawnOnTheModelImage() async throws {
        let page = UIGraphicsImageRenderer(size: CGSize(width: 816, height: 1056)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 816, height: 1056))
        }
        let mark = InkyPageAnnotation(id: UUID(), action: .star(StarAction(point: NormPoint(x: 0.5, y: 0.5))), bounds: NormRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1))
        let plain = InkyLocalization.modelImages(pageImage: page, lasso: nil)
        let marked = InkyLocalization.modelImages(pageImage: page, lasso: nil, annotations: [mark])
        #expect(plain[0].pngData != marked[0].pngData)
        let request = await InkyContextBuilder.makeRequest(question: "q", pageImage: page, recognizedText: [], lassoRegion: nil,
                                                     pageAspectRatio: 816.0 / 1056.0, notebookTitle: nil, annotations: [mark])
        #expect(request.pageAnnotations == [mark])
        #expect(request.images.count == 1)
    }
}

@Suite("Blank detection")
struct InkyBlankDetectionTests {
    /// Lined paper, a printed prompt, an empty box, a box with an answer, an underline blank.
    @MainActor
    static func worksheet() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 816, height: 1056)).image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill(); cg.fill(CGRect(x: 0, y: 0, width: 816, height: 1056))
            cg.setStrokeColor(UIColor(red: 0.77, green: 0.82, blue: 0.9, alpha: 1).cgColor)
            for y in stride(from: 96.0, to: 1040, by: 32) { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: 816, y: y)) }
            cg.strokePath()
            let font = UIFont.systemFont(ofSize: 24)
            ("1.  7 × 8 =" as NSString).draw(at: CGPoint(x: 80, y: 150), withAttributes: [.font: font])
            ("2.  9 + 3 =" as NSString).draw(at: CGPoint(x: 80, y: 250), withAttributes: [.font: font])
            ("The answer is" as NSString).draw(at: CGPoint(x: 80, y: 350), withAttributes: [.font: font])
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(2)
            cg.stroke(CGRect(x: 300, y: 144, width: 120, height: 42))
            cg.stroke(CGRect(x: 300, y: 244, width: 120, height: 42))
            ("12" as NSString).draw(at: CGPoint(x: 340, y: 250), withAttributes: [.font: font])
            cg.move(to: CGPoint(x: 260, y: 378)); cg.addLine(to: CGPoint(x: 440, y: 378)); cg.strokePath()
        }
    }

    @MainActor
    @Test func findsEmptyBoxesAndUnderlinesOnly() async throws {
        let image = try #require(Self.worksheet().cgImage)
        let text = await InkyLocalization.recognizeText(in: image)
        let blanks = await InkyLocalization.detectBlanks(in: image, text: text)
        let box = NormRect(CGRect(x: 300, y: 144, width: 120, height: 42), in: CGSize(width: 816, height: 1056))
        let filled = NormRect(CGRect(x: 300, y: 244, width: 120, height: 42), in: CGSize(width: 816, height: 1056))
        #expect(blanks.contains { $0.intersectionOverUnion(box) > 0.8 }, "\(blanks)")
        #expect(!blanks.contains { $0.intersectionOverUnion(filled) > 0.3 }, "a box with an answer is not blank")
        #expect(blanks.contains { $0.minY > 0.3 && $0.maxY < 0.37 && $0.minX > 0.3 }, "underline blank")
        #expect(blanks.count == 2)

        var request = Fixtures.sampleRequest()
        request.blanks = [box]
        #expect(InkyPromptBuilder.userText(for: request).contains("Empty boxes detected on the page"))
    }

    @MainActor
    @Test func gridPaperIsNotBlanks() async throws {
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 816, height: 1056)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 816, height: 1056))
            ctx.cgContext.setStrokeColor(UIColor(red: 0.88, green: 0.91, blue: 0.95, alpha: 1).cgColor)
            for v in stride(from: 0.0, to: 1056, by: 24) {
                ctx.cgContext.move(to: CGPoint(x: v, y: 0)); ctx.cgContext.addLine(to: CGPoint(x: v, y: 1056))
                ctx.cgContext.move(to: CGPoint(x: 0, y: v)); ctx.cgContext.addLine(to: CGPoint(x: 816, y: v))
            }
            ctx.cgContext.strokePath()
        }.cgImage)
        #expect(await InkyLocalization.detectBlanks(in: image, text: []).isEmpty)
    }
}

@Suite("Conversation memory")
@MainActor
struct InkyConversationTests {
    @Test func keepsRecentTurnsPerPage() {
        let conversation = InkyConversation()
        conversation.maxTurns = 2
        let page = UUID(), other = UUID()
        for i in 1...3 { conversation.record(InkyTurn(question: "q\(i)", actions: []), pageID: page) }
        #expect(conversation.history(for: page).map(\.question) == ["q2", "q3"])
        #expect(conversation.history(for: other).isEmpty)
        conversation.reset(pageID: page)
        #expect(conversation.history(for: page).isEmpty)
    }

    @Test func oldTurnsExpire() {
        let conversation = InkyConversation()
        let page = UUID()
        conversation.record(InkyTurn(question: "old", actions: [], date: Date(timeIntervalSinceNow: -3600)), pageID: page)
        conversation.record(InkyTurn(question: "new", actions: []), pageID: page)
        #expect(conversation.history(for: page).map(\.question) == ["new"])
    }
}

extension Fixtures {
    static func mark() -> InkyPageAnnotation {
        let region = NormRect(x: 0.1, y: 0.07, width: 0.5, height: 0.04)
        return InkyPageAnnotation(id: UUID(), action: .highlight(HighlightAction(region: region, color: .yellow, note: nil)),
                                  bounds: region, question: "highlight the title")
    }
}
