# Interface requests

Changes other owners need to make so AICore features reach the app. Newest last.

## 1. InkySession: send marks + conversation, apply removals, record turns — from AICore (feat/ai-core)

**Owner:** lead (app shell). **Status:** ✅ done (applied on main during the integration merge; patch file removed).

Why: follow-ups ("now explain why", "undo that", "no, the other one") need the model to see what is already on
the page and what was said, and the app has to act on `removeAnnotations`. Until this lands, AICore still works
(every new field defaults to empty), but follow-ups have no memory and "undo that" only produces a toast.

What the patch does (InkySession.swift, ~30 lines):
1. Builds the request with `InkyContextBuilder.makeRequest(...)`, passing
   - `annotations:` `editor.annotations` mapped to `InkyPageAnnotation(id:action:bounds:isHidden:question:)`, with
     `bounds = InkyAnnotationGeometry.bounds(for:pageSize:)` (so moved marks are where the student sees them).
     The model sees them as `m1…mN` (orange outlines + ids on the page image, and a text list).
   - `history:` `conversation.history(for: editor.page.id)` from a new `let conversation = InkyConversation()`.
2. On `.completed(response)`: `for id in response.removedAnnotationIDs { editor.deleteAnnotation(id) }`
   (`ValidatingInkyModelClient` already resolved the model's short ids to annotation UUIDs).
3. After the turn: `conversation.record(InkyTurn(question:actions:createdAnnotationIDs:removedAnnotationIDs:), pageID:)`,
   where `createdAnnotationIDs` = annotation ids that were not there before the turn.
4. Doesn't show "Inky had nothing to add." when the turn only removed marks.

## 2. SpeechInput: STEM vocabulary + punctuation for voice questions

**Status:** ✅ done (same patch).

Same patch, SpeechInput.swift (2 lines): `request.addsPunctuation = true` and
`request.contextualStrings = InkyVoiceHints.contextualStrings` (AICore list of STEM words that dictation tends to
mishear: carbonyl, asymptote, hypotenuse, metaphase, …). Live transcript in the popover already works
(partial results stream into `session.question`); nothing else needed there.

## Notes for the lead (no action required)
- `InkyClientFactory.makeDefault()` now returns `ValidatingInkyModelClient(base:)` around the proxy/mock client:
  every action is checked before it reaches `InkySession`, and an invalid answer is retried once. The event
  contract is unchanged (`.action`s, then exactly one `.completed` whose actions are exactly those forwarded).
- Schema v2 adds a root `removeAnnotations: [String]` before `actions`. `InkyResponse(actions:)` still compiles
  (defaulted), and decoding tolerates its absence.
- The model is told to put a `say` first, so the toast appears with the first streamed action.
