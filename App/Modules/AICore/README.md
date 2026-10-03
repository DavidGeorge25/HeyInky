# AICore

Everything between "the student asked something" and "here are typed, validated actions". No UI.

## Owns
| File | Role |
|---|---|
| `Contract/InkyAction.swift` | Swift mirror of `/shared/inky_actions.schema.json` (`InkyResponse`, `InkyAction`, `NormRect`, …). |
| `InkyModelClient.swift` | **The** protocol all model access goes through, plus `InkyRequest` (the context packet), `InkyPageAnnotation`, `InkyTurn`, `InkyCorrection`, `InkyStreamEvent`, `InkyClientError`. |
| `InkyConfig.swift` | Model name (one constant), proxy URL/token, mock switch, `InkyClientFactory`. |
| `InkyLocalization.swift` | Page PNG + labeled grid (0.1 labeled on all edges, 0.05 minor), lasso crop, existing-mark outlines, Vision OCR with word positions, **blank detection** (`InkMask`), and `InkyContextBuilder.makeRequest` (one call → full packet). |
| `InkyPromptBuilder.swift` | Responses API body. Text section: text lines + word@x positions, detected blanks, existing marks `m1…`, conversation history, retry correction. Prompt + schema bundled from `/shared`. |
| `InkyResponseValidator.swift` | Semantic checks beyond the schema (regions inside the page, SMILES/SMARTS syntax, safe graph expressions, non-empty text, known mark ids). Mirrored in `evals/inky_eval/validate.py`. |
| `ValidatingInkyModelClient.swift` | Wraps any client: forwards only valid actions as they stream, retries **once** with feedback on invalid/truncated/malformed output, resolves `m2` → annotation UUID. `InkyClientFactory` always wraps. |
| `InkyConversation.swift` | Per-page follow-up memory (last 4 turns, 30 min). |
| `InkyVoiceHints.swift` | STEM `contextualStrings` for speech recognition. |
| `ResponsesStreamParser.swift` | SSE → events; decodes each action as soon as its JSON object closes. |
| `ProxyInkyModelClient.swift` / `MockInkyModelClient.swift` | `/proxy` client / canned offline answers. |

## Interface the rest of the app relies on
```swift
protocol InkyModelClient: Sendable {
    func respond(to request: InkyRequest) -> AsyncThrowingStream<InkyStreamEvent, Error>
}
// Events: .textDelta(String), .action(InkyAction) (incremental, already validated),
//         .completed(InkyResponse) (exactly once, last; actions == the forwarded ones;
//          removedAnnotationIDs = marks to delete for "undo that")
let request = await InkyContextBuilder.makeRequest(question:pageImage:recognizedText:lassoRegion:lassoPath:
                                                   pageAspectRatio:notebookTitle:annotations:history:)
```
Shell wiring for marks/history/removals is in `/INTERFACE_REQUESTS.md` (patch included).

## Rules
- The app never holds an API key. Real calls go through `/proxy`.
- **Schema key order matters.** Strict structured outputs generate properties in schema order; the schema text is
  spliced in verbatim (`InkyPromptBuilder.bodyData`). `type` first in every action; root `removeAnnotations` before `actions`.
- Changing the schema: edit `/shared/inky_actions.schema.json`, mirror in `InkyAction.swift`, add a fixture, run
  `npm run check` (proxy) and the Swift tests (`InkyActionSchemaSyncTests`).
- Changing validation: update both validators and `/shared/fixtures/validation/cases.json`.
- Changing the prompt or localization: run the evals (`/evals/README.md`) and record results in `/evals/RESULTS.md`.

## Next steps
1. "Sign in with ChatGPT" client (same body from `InkyPromptBuilder.bodyData`) + factory switch.
2. Re-run the full eval on the production model when quota allows (see `evals/RESULTS.md`), then pick the model.
3. Set-of-marks for drawings (number ink clusters on the image so the model can pick exact boxes for diagram parts).
4. Cache OCR / blank detection per page version (each takes ~100–300 ms on device).
