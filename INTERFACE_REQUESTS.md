# Interface requests

Changes a module agent needs from another owner (usually the lead / app shell). Grouped by the
requesting module; newest group last. Each request carries a **Status** line.

## From AICore (feat/ai-core)

### 1. InkySession: send marks + conversation, apply removals, record turns — from AICore (feat/ai-core)

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

### 2. SpeechInput: STEM vocabulary + punctuation for voice questions

**Status:** ✅ done (same patch).

Same patch, SpeechInput.swift (2 lines): `request.addsPunctuation = true` and
`request.contextualStrings = InkyVoiceHints.contextualStrings` (AICore list of STEM words that dictation tends to
mishear: carbonyl, asymptote, hypotenuse, metaphase, …). Live transcript in the popover already works
(partial results stream into `session.question`); nothing else needed there.

### Notes for the lead (no action required)
- `InkyClientFactory.makeDefault()` now returns `ValidatingInkyModelClient(base:)` around the proxy/mock client:
  every action is checked before it reaches `InkySession`, and an invalid answer is retried once. The event
  contract is unchanged (`.action`s, then exactly one `.completed` whose actions are exactly those forwarded).
- Schema v2 adds a root `removeAnnotations: [String]` before `actions`. `InkyResponse(actions:)` still compiles
  (defaulted), and decoding tolerates its absence.
- The model is told to put a `say` first, so the toast appears with the first streamed action.

## From Chemistry (feat/chemistry)

### 1. Chemistry → lead: wire `MoleculeCardContext` into the Inky layer

**Status:** ✅ done — `InkyLayerView.moleculeCardContext(for:)`; `commit` re-reads the annotation by id so a
concurrent move/hide isn't overwritten. Card annotations use `.accessibilityElement(children: .contain)`.

**Why.** `MoleculeCardView(action:)` only receives the action, so the card can't persist edits:
Ketcher edits (new SMILES), starring / hiding a group, and resizing. Today those edits live in
view state and are lost when the view is recreated (page change, relaunch). The card also can't
scale its chrome with page zoom.

**What.** The Chemistry module defines (in `Modules/Chemistry/MoleculeCardContext.swift`):

```swift
struct MoleculeCardContext: Sendable {
    var scale: CGFloat = 1          // page zoom (same value InkyCardContainer gets)
    var pageSize: CGSize?           // page points; enables the resize grip
    var commit: (@MainActor @Sendable (InsertMoleculeCardAction) -> Void)?
}
extension EnvironmentValues { @Entry var moleculeCardContext = MoleculeCardContext() }
```

Suggested patch in `HeyInky/InkyLayer/InkyLayerView.swift`, inside the `ForEach` in `InkyLayerView`
(it has `editor`, `annotation`, `pageSize`, `scale`):

```swift
InkyAnnotationView(annotation: annotation, pageSize: pageSize, scale: scale)
    .environment(\.moleculeCardContext, MoleculeCardContext(
        scale: scale,
        pageSize: pageSize,
        commit: { [editor] updated in
            var copy = annotation
            copy.action = .insertMoleculeCard(updated)
            editor.updateAnnotation(copy)
        }
    ))
```

Notes:
- The resize grip commits a new `near` rect whose origin is the card's current
  `InkyAnnotationGeometry.cardRect` origin and whose size grows/shrinks with the drag (min
  `minCardSize`). The user `offset` is untouched.
- `highlightGroups == ["none"]` is how the card stores "user hid every highlight" (`[]` keeps
  meaning "all detected groups"). The model never needs to produce it.
- Nothing else in the shell changes; everything is optional, so the card works without it.

### 2. Chemistry → lead / AI agent (optional): prompt hint for `insertMoleculeCard`

**Status:** ✅ done — prompt lists group names and reaction SMILES next to the SMARTS examples.

The card accepts library group ids/names in `highlightGroups` / `starGroups` as well as SMARTS
(e.g. `"ester"`, `"carboxylic acid"`, `"amide"`, `"β-lactam"`), and reaction SMILES
(`"CCO.CC(=O)O>>CC(=O)OCC.O"`, agents between the `>`s are shown over the arrow). Names are often
more reliable from the model than hand-written SMARTS. A one-line hint in
`shared/inky_system_prompt.md` would let the model use both. Group ids are listed in
`App/Modules/Chemistry/Resources/ChemistryWeb/functional-groups.json`. No schema change needed.
