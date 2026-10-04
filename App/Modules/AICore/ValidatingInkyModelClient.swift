import Foundation

/// Wraps any client: checks every action as it streams (`InkyResponseValidator`), forwards
/// only valid ones, and if the answer had problems (invalid actions, malformed or truncated
/// JSON, unknown mark ids) asks the model once more, telling it what was wrong and what was
/// already applied. Short mark ids in `removeAnnotations` are resolved to annotation UUIDs.
///
/// Event contract for consumers is unchanged: `.action`s as they become valid, then exactly
/// one `.completed` whose `actions` are exactly the forwarded actions, in order.
struct ValidatingInkyModelClient: InkyModelClient {
    /// App-side check for one action: `.valid` (possibly adjusted) or `.invalid(problem)`.
    /// The Bool is true on the last attempt, when minor problems should be let through.
    typealias DeepCheck = @Sendable (InkyAction, InkyRequest, Bool) async -> InkyResponseValidator.Outcome

    let base: any InkyModelClient
    var maxRetries = 1
    var deepCheck: DeepCheck? = InkyClientFactory.deepCheck

    func respond(to request: InkyRequest) -> AsyncThrowingStream<InkyStreamEvent, Error> {
        let base = self.base
        let maxRetries = self.maxRetries
        let deepCheck = self.deepCheck
        return AsyncThrowingStream { continuation in
            let task = Task {
                var forwarded: [InkyAction] = []
                var removals: [UUID] = []
                var attempt = 0
                var attemptRequest = request

                while true {
                    var problems: [String] = []
                    var streamedThisAttempt = 0
                    var completedResponse: InkyResponse?

                    let isFinalAttempt = attempt >= maxRetries
                    func accept(_ action: InkyAction) async {
                        switch InkyResponseValidator.check(action, request: request) {
                        case .valid(var fixed):
                            // Deeper checks that need the app (RDKit, the diagram renderer).
                            if let deepCheck {
                                switch await deepCheck(fixed, request, isFinalAttempt) {
                                case .valid(let checked): fixed = checked
                                case .invalid(let problem):
                                    problems.append(problem)
                                    return
                                }
                            }
                            // A retry must not repeat what is already on the page.
                            if attempt > 0, forwarded.contains(fixed) { return }
                            forwarded.append(fixed)
                            continuation.yield(.action(fixed))
                        case .invalid(let problem):
                            problems.append(problem)
                        }
                    }

                    do {
                        for try await event in base.respond(to: attemptRequest) {
                            switch event {
                            case .textDelta:
                                continuation.yield(event)
                            case .action(let action):
                                streamedThisAttempt += 1
                                await accept(action)
                            case .completed(let response):
                                for action in response.actions.dropFirst(streamedThisAttempt) { await accept(action) }
                                completedResponse = response
                            }
                        }
                    } catch InkyClientError.invalidResponse(let message) {
                        problems.append("the output was not valid JSON for the schema (\(message.prefix(160)))")
                    } catch InkyClientError.modelFailed(let message) where message.contains("incomplete") {
                        problems.append("the answer was cut off (\(message)); answer with fewer, shorter actions")
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }

                    if let response = completedResponse {
                        problems += InkyResponseValidator.responseProblems(response, request: request)
                        for raw in response.removeAnnotations {
                            if let id = request.annotationID(forShortID: raw), !removals.contains(id) { removals.append(id) }
                        }
                    }

                    let somethingHappened = !forwarded.isEmpty || !removals.isEmpty
                    if problems.isEmpty || attempt >= maxRetries {
                        if problems.isEmpty || somethingHappened {
                            continuation.yield(.completed(InkyResponse(
                                removeAnnotations: removals.map(\.uuidString), actions: forwarded
                            )))
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: InkyClientError.invalidResponse(problems.joined(separator: "; ")))
                        }
                        return
                    }
                    if Task.isCancelled {
                        continuation.finish(throwing: InkyClientError.cancelled)
                        return
                    }
                    attempt += 1
                    attemptRequest = request
                    attemptRequest.correction = InkyCorrection(problems: problems, alreadyApplied: forwarded)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
