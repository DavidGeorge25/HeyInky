# AICore

Everything between "the student asked something" and "here are typed actions". No UI.

## Owns
| File | Role |
|---|---|
| `Contract/InkyAction.swift` | Swift mirror of `/shared/inky_actions.schema.json` (`InkyAction`, `NormRect`, `NormPoint`, `GraphSpec`, …). |
| `InkyModelClient.swift` | **The** protocol all model access goes through, plus `InkyRequest`, `InkyStreamEvent`, `InkyClientError`. |
| `InkyConfig.swift` | Model name (one constant), proxy URL/token, mock switch, `InkyClientFactory`. |
| `InkyPromptBuilder.swift` | Builds the OpenAI Responses API body. Prompt + schema are bundled from `/shared`. |
| `ResponsesStreamParser.swift` | SSE → events; decodes each action as soon as its JSON object closes. |
| `ProxyInkyModelClient.swift` | Talks to `/proxy` (`POST /inky`). |
| `MockInkyModelClient.swift` | Canned actions for tests/UI tests/demos (`-InkyUseMockClient YES`). |
| `InkyLocalization.swift` | **The** localization function: page PNG + labeled 0–1 grid, lasso crop, Vision OCR. Tune here. |

## Interface the rest of the app relies on
```swift
protocol InkyModelClient: Sendable {
    func respond(to request: InkyRequest) -> AsyncThrowingStream<InkyStreamEvent, Error>
}
// Events: .textDelta(String), .action(InkyAction) (incremental), .completed(InkyResponse) (exactly once, last)
// Errors: InkyClientError (.server, .network, .modelFailed, .invalidResponse, .cancelled)
```
`InkySession` (app) consumes the stream: it applies `.action` events immediately, then any
actions in `.completed` beyond those already applied.

## Rules
- The app never holds an API key. Real calls go through `/proxy`.
- **Schema key order matters.** OpenAI strict structured outputs generate properties in schema
  order. The schema text is spliced into the request verbatim (`InkyPromptBuilder.bodyData`);
  never round-trip it through a Swift dictionary. `type` must be the first property of each action.
- Changing the schema: edit `/shared/inky_actions.schema.json`, mirror in `InkyAction.swift`, add
  a fixture in `/shared/fixtures`, then run both `npm test` (proxy) and the Swift tests
  (`InkyActionSchemaSyncTests` fails on drift).

## Next steps for the AICore agent
1. **Sign in with ChatGPT**: add `ChatGPTInkyModelClient` (same body from `InkyPromptBuilder.bodyData`,
   POST straight to OpenAI with the user's token) and switch it in `InkyClientFactory`. One file.
2. Conversation memory: send the previous turn(s) (question + returned actions) for follow-ups
   ("now circle the units"). Consider `previous_response_id` (needs `store: true` in the proxy).
3. Tune `InkyLocalization` (grid density, image size, crop padding) with an eval set: pages + questions
   + expected regions, scored by IoU (see `LiveProxyIntegrationTests` for the pattern).
4. Cost/latency: measure image token use; try JPEG for photo-heavy pages; cache OCR per page version.
5. Handle `response.incomplete` (max tokens) by asking for fewer actions.
