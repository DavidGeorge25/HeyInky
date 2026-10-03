# InkyCharacter

Inky, the AI pen character: its look, poses, motion, the on-page "hop and draw" performance,
feedback (haptics + sounds), and the app icon / launch artwork.

## Interface
```swift
enum InkyCharacterState: Equatable, Sendable, CaseIterable {
    case idle, listening, thinking, speaking, happy, hopping, writing
}

struct InkyCharacterView: View {
    var state: InkyCharacterState = .idle
    var size: CGFloat = 32
    var isAnimated = true          // false = static reference pose (snapshots)
}
```
Always exactly `size × size`. Reads from 20 pt (toasts) to 84 pt (on the page) and 1024 px (icon).

| Piece | File | Used by |
|---|---|---|
| Pose model + per-state motion (pure function of time) | `InkyPose.swift` | `InkyCharacterView`, tests |
| Canvas drawing, palette | `InkyFigure.swift` | everything that shows Inky |
| Character view (blends state changes, Reduce Motion) | `InkyCharacterView.swift` | shell views |
| Choreography: queue → enter/hop → draw → celebrate → leave | `InkyChoreographer.swift` | `PageEditorModel.choreographer`, `InkySession.apply` |
| Inky on the page (position, arc, squash, shadow) | `InkyPerformerView.swift` | `InkyLayerView` |
| Nib path per annotation kind (shared with stroke-reveal) | `InkyStroke.swift` | choreographer, performer |
| Haptics (incl. Apple Pencil Pro) + synthesized sounds | `InkyFeedback.swift` | session, choreographer |
| Avatar, ink-dot thinking indicator, ink-drop shape, type | `InkyChrome.swift` | ask card, toast, sidebar, button |
| App icon + launch art | `InkyArtwork.swift` | `InkyArtworkTests` renders the PNGs |

## Design
An original chubby fountain pen standing on its nib: indigo barrel (`Theme.accent`), white grip
ring, deep-ink nib with slit and breather hole, big eyes on the barrel, and an **ink drop** on its
head that lags behind the body like an ear. Ink drops also splash off when happy; thought dots and
the "away" seat are ink drops too. Palette: accent, deep ink, white, a soft blush.

| State | Motion |
|---|---|
| idle | breathing bob, slow look-around, blinks (double-blink every other time) |
| listening | wide eyes, sound arcs closing in, ink-drop "ear" wiggle, nod |
| thinking | looks up, sways, three thought dots fill in turn |
| speaking | talking mouth (two-frequency rhythm), bob |
| happy | ^ ^ eyes, bounce with squash, ink splashes |
| hopping | wide eyes, "o" mouth, drop streaming |
| writing | leans like a held pen, fast scribble wobble around the nib, tongue out |

## Performance on the page
`InkySession.apply` adds each annotation and calls `editor.choreographer.perform(_:pageSize:)`.
The annotation stays hidden (`isPending`) until Inky lands at its start, then is revealed under
the nib with the stroke's progress (`InkyAnnotationView(progress:)`). The reply `say()` toast is
held until drawing is done (`afterPerformance`). Without an on-screen layer (`hasStage == false`,
e.g. headless tests) annotations appear immediately.

- **Reduce Motion:** no hopping or drawing; annotations fade in one after another; the character
  holds each state's reference pose and state changes cross-fade.
- `-InkyMotionScale <x>` multiplies all durations (UI tests use 3; nice for screen recordings).
- **Sounds:** "Inky Sounds" in the toolbar's Inky menu (`InkySoundsEnabled`, default on). Tones
  are synthesized once into Caches and played as system sounds (mix with everything, follow the
  alert volume, never touch the speech audio session).

## Tests
- `InkyCharacterTests`: snapshot per state + 20/34/64 pt sheets, exact frame size, never drawn
  outside the frame, states distinct, blink/bob ranges, pose blending.
- `InkyChoreographyTests`: nib paths per kind, full sequence order, hidden-until-arrival, hop arc,
  Reduce Motion fades, no-stage fallback, sound levels.
- `InkyArtworkTests`: committed icon/launch PNGs match the SwiftUI art; icon opaque and legible small.
- `InkyChoreographyUITests`: hop-to-target sequence with the mock client.

Re-record snapshots: `TEST_RUNNER_INKY_RECORD_SNAPSHOTS=1 xcodebuild test … -only-testing:HeyInkyTests/InkyCharacterTests`.
Re-render icon/launch: `TEST_RUNNER_INKY_RECORD_ARTWORK=1 xcodebuild test … -only-testing:HeyInkyTests/InkyArtworkTests`.

## Next steps
- Molecule/graph cards: once real renderers land, Inky could "tap" interactive elements.
- Pencil Pro: anchor `UICanvasFeedbackGenerator` haptics at the hover location instead of the window center.
- Inky walking off toward the floating button (needs the button's position in page space).
