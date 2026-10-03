import Foundation

/// Talks to the Hey Inky proxy (/proxy), which holds the OpenAI key and streams
/// Responses API events back. The app never sees the key.
struct ProxyInkyModelClient: InkyModelClient {
    let baseURL: URL
    let token: String?
    var session: URLSession = .shared
    var model: String = InkyConfig.modelName

    func respond(to request: InkyRequest) -> AsyncThrowingStream<InkyStreamEvent, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(for: request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw InkyClientError.server(status: status, message: Self.errorMessage(from: body))
                    }
                    var parser = ResponsesStreamParser()
                    for try await line in bytes.lines {
                        for event in try parser.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    for event in try parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: InkyClientError.cancelled)
                } catch let error as InkyClientError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: InkyClientError.cancelled)
                } catch {
                    continuation.finish(throwing: InkyClientError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeURLRequest(for request: InkyRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("inky"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 90
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token { urlRequest.setValue(token, forHTTPHeaderField: "X-Inky-Token") }
        urlRequest.httpBody = try InkyPromptBuilder.bodyData(for: request, model: model)
        return urlRequest
    }

    static func errorMessage(from body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: body, encoding: .utf8) ?? "unknown error"
    }
}
