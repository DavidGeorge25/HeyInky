import Foundation
import Testing
@testable import HeyInky

@Suite("Responses stream parsing")
struct ResponsesStreamParserTests {
    static func deltaLine(_ text: String) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": text])
        return "data: " + String(data: payload, encoding: .utf8)!
    }

    @Test func emitsActionsAsTheyCloseThenCompletes() throws {
        let json = String(data: try Fixtures.data("all_actions"), encoding: .utf8)!
        var parser = ResponsesStreamParser()
        var actions: [InkyAction] = []
        var completed: InkyResponse?
        // Split into awkward 7-character chunks.
        var index = json.startIndex
        while index < json.endIndex {
            let end = json.index(index, offsetBy: 7, limitedBy: json.endIndex) ?? json.endIndex
            for event in try parser.consume(line: Self.deltaLine(String(json[index..<end]))) {
                if case .action(let a) = event { actions.append(a) }
            }
            index = end
        }
        #expect(actions.count == 11)
        for event in try parser.consume(line: #"data: {"type":"response.completed","response":{}}"#) {
            if case .completed(let r) = event { completed = r }
        }
        #expect(completed?.actions == actions)
    }

    @Test func scannerIgnoresBracesInsideStrings() {
        var scanner = IncrementalActionScanner()
        let found = scanner.feed(#"{"actions":[{"type":"say","text":"a } { \" ] tricky"},{"type":"star","point":{"x":0.1,"y":0.2}}]}"#)
        #expect(found.count == 2)
        #expect(found[1].contains("\"point\""))
    }

    @Test func finishWithoutCompletedEventStillDecodes() throws {
        var parser = ResponsesStreamParser()
        _ = try parser.consume(line: Self.deltaLine(#"{"actions":[{"type":"say","text":"hi"}]}"#))
        let events = try parser.finish()
        guard case .completed(let response) = events.first else { Issue.record("no completion"); return }
        #expect(response.actions == [.say(SayAction(text: "hi"))])
    }

    @Test func failureEventsThrow() {
        var parser = ResponsesStreamParser()
        #expect(throws: InkyClientError.self) {
            try parser.consume(line: #"data: {"type":"response.failed","response":{"error":{"message":"boom"}}}"#)
        }
        #expect(throws: InkyClientError.self) {
            try parser.consume(line: #"data: {"type":"error","message":"rate limited"}"#)
        }
    }

    @Test func ignoresNonDataLines() throws {
        var parser = ResponsesStreamParser()
        #expect(try parser.consume(line: "event: response.created").isEmpty)
        #expect(try parser.consume(line: ": keep-alive").isEmpty)
        #expect(throws: InkyClientError.self) { try parser.finish() }
    }
}

@Suite("Prompt builder")
struct InkyPromptBuilderTests {
    @Test func bodyHasStrictSchemaImagesAndQuestion() throws {
        let body = InkyPromptBuilder.body(for: Fixtures.sampleRequest(lasso: NormRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)))
        #expect(body["model"] as? String == InkyConfig.modelName)
        #expect(body["stream"] as? Bool == true)
        #expect((body["instructions"] as? String)?.contains("You are Inky") == true)

        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        #expect(format?["strict"] as? Bool == true)

        let input = body["input"] as? [[String: Any]]
        let content = input?.first?["content"] as? [[String: Any]] ?? []
        let image = content.first { $0["type"] as? String == "input_image" }
        #expect((image?["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        let texts = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        #expect(texts.contains("Student: highlight the title"))
        #expect(texts.contains("[0.100, 0.070, 0.500, 0.040] \"Lecture 7\""))
        #expect(texts.contains("lassoed this region: [0.100, 0.200, 0.300, 0.100]"))

        // The serialized body is valid JSON and carries the full schema.
        let data = try InkyPromptBuilder.bodyData(for: Fixtures.sampleRequest())
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let schema = ((parsed?["text"] as? [String: Any])?["format"] as? [String: Any])?["schema"] as? [String: Any]
        #expect(schema?["$defs"] != nil)
    }

    /// Regression: strict structured outputs follow schema key order. If `type` isn't the
    /// first property of every action, the model can only produce some action types.
    @Test func serializedSchemaKeepsTypeFirstInEveryAction() throws {
        let json = String(decoding: try InkyPromptBuilder.bodyData(for: Fixtures.sampleRequest()), as: UTF8.self)
        #expect(json.contains(InkyPromptBuilder.actionSchemaText()))
        for type in InkyActionType.allCases {
            let def = try #require(json.range(of: "\"\(type.rawValue)\": {"))
            let properties = try #require(json.range(of: "\"properties\": {", range: def.upperBound..<json.endIndex))
            let firstKey = json[properties.upperBound...].drop { $0 == " " || $0 == "\n" }.prefix(6)
            #expect(firstKey == "\"type\"", "\(type.rawValue): type must be the first property")
        }
    }
}

/// Serves canned HTTP responses to URLSession.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastRequestBody = data
        } else {
            Self.lastRequestBody = request.httpBody
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite("Proxy client", .serialized)
struct ProxyInkyModelClientTests {
    func client() -> ProxyInkyModelClient {
        ProxyInkyModelClient(baseURL: URL(string: "http://proxy.test")!, token: "tok", session: StubURLProtocol.session())
    }

    @Test func streamsActionsFromSSE() async throws {
        let json = #"{"actions":[{"type":"star","point":{"x":0.2,"y":0.3}},{"type":"say","text":"Starred it."}]}"#
        let delta = ResponsesStreamParserTests.deltaLine(json)
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data("event: response.output_text.delta\n\(delta)\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{}}\n\n".utf8)

        var actions: [InkyAction] = []
        var completed: InkyResponse?
        for try await event in client().respond(to: Fixtures.sampleRequest()) {
            switch event {
            case .action(let a): actions.append(a)
            case .completed(let r): completed = r
            case .textDelta: break
            }
        }
        #expect(actions.count == 2)
        #expect(completed?.actions.count == 2)

        let sent = try JSONSerialization.jsonObject(with: StubURLProtocol.lastRequestBody ?? Data()) as? [String: Any]
        #expect(sent?["model"] as? String == InkyConfig.modelName)
    }

    @Test func surfacesServerErrorMessage() async {
        StubURLProtocol.status = 401
        StubURLProtocol.body = Data(#"{"error":{"message":"Missing or wrong X-Inky-Token"}}"#.utf8)
        do {
            for try await _ in client().respond(to: Fixtures.sampleRequest()) {}
            Issue.record("expected an error")
        } catch let error as InkyClientError {
            #expect(error == .server(status: 401, message: "Missing or wrong X-Inky-Token"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func requestCarriesTokenAndPath() throws {
        let request = try client().makeURLRequest(for: Fixtures.sampleRequest())
        #expect(request.url?.absoluteString == "http://proxy.test/inky")
        #expect(request.value(forHTTPHeaderField: "X-Inky-Token") == "tok")
        #expect(request.httpMethod == "POST")
    }
}

@Suite("Mock client")
struct MockInkyModelClientTests {
    @Test func defaultAnswerTargetsFirstTextLine() async throws {
        var final: InkyResponse?
        for try await event in MockInkyModelClient(delay: .zero).respond(to: Fixtures.sampleRequest()) {
            if case .completed(let r) = event { final = r }
        }
        guard case .highlight(let h) = final?.actions.first else { Issue.record("expected highlight"); return }
        #expect(h.region.intersectionOverUnion(NormRect(x: 0.1, y: 0.07, width: 0.5, height: 0.04)) > 0.7)
    }

    @Test func explainOpensSidebar() {
        let actions = MockInkyModelClient.cannedActions(for: Fixtures.sampleRequest(question: "explain this"))
        #expect(actions.first?.type == .openSidebar)
    }
}
