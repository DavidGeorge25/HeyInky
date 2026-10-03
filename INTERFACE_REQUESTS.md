# Interface requests

Requests from module agents for changes outside their module. Newest last.
Each entry: who → owner, what, why, status.

## InkyCharacter → lead (feat/character)

Small shell edits were needed to wire the character in; they are already made on
`feat/character` and kept minimal. Please review/accept or move them as you prefer.

1. **`PageEditorModel.choreographer`** (`let choreographer = InkyChoreographer()`) — one per page,
   so the Inky layer can hide annotations until Inky draws them. *Done on branch.*
2. **`InkySession.apply`**: after `editor.addAnnotation`, call
   `editor.choreographer.perform(added, pageSize:)`; `say` toasts go through
   `editor.choreographer.afterPerformance { … }` so Inky replies when it has finished drawing
   (immediate when nothing is queued or no page is on screen, so `InkySessionTests` are unchanged).
   Feedback cues `InkyFeedback.play(.summon/.send/.error)`. *Done on branch.*
3. **`InkyLayerView`**: filters `choreographer.isPending` annotations, renders through
   `InkyRevealingAnnotationView` (stroke-reveal), adds `InkyPerformerView` on top, `.transition(.opacity)`
   on annotations (Reduce Motion fade). *Done on branch.*
4. **`NotebookView`**: `InkyFloatingButton(isAway: editor.choreographer.isOnStage)` and an
   "Inky Sounds" toggle in `InkyLayerMenu`. *Done on branch.*
5. **`project.yml`**: `UILaunchScreen` → `UIImageName: LaunchInky`, `UIColorName: LaunchBackground`.
   *Done on branch.*
6. **Request (not done):** expose the floating button's frame in page coordinates (or a
   "home" point) so Inky can hop back to the button instead of fading out at the last annotation.
7. **Request (not done):** `InkySession` could expose `characterState = .writing` while
   `choreographer.isOnStage`, if other surfaces should reflect that Inky is busy drawing.
