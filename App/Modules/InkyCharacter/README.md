# InkyCharacter

Inky, the AI pen character: its look, poses and motion.

## Interface you must implement
```swift
enum InkyCharacterState: Equatable, Sendable { case idle, listening, thinking, speaking, happy }

struct InkyCharacterView: View {
    var state: InkyCharacterState = .idle
    var size: CGFloat = 32
}
```
Keep these names and the initializer. Used by:
- floating summon button (`InkyFloatingButton`, 34 pt),
- ask popover (`InkyAskCard`, 30 pt; `.listening` while the mic is on, `.thinking` while waiting),
- toasts (22 pt, `.happy`), sidebar header (26 pt, `.speaking` during TTS),
- library empty state (64 pt).
`InkySession.characterState` maps app state to `InkyCharacterState`.

The current view is a **placeholder** (accent-colored nib with eyes and simple animation).

## Requirements
- Extremely minimal, calm, friendly; one accent color (`Theme.accent`) plus white.
- Must read clearly from 20 pt to 64 pt; vector only (SwiftUI shapes or a symbol/vector asset).
- Subtle motion per state; respect Reduce Motion (`@Environment(\.accessibilityReduceMotion)`).
- No layout shifts: the view must always occupy exactly `size × size`.

## Ideas
- Inky "writing" its answer: a small animated ink trail that leads to newly inserted annotations.
- Blink idle loop; ear-like wiggle when listening; nib tilt when thinking.
