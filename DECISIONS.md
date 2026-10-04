# Decisions

Newest last. Each entry: decision — why.

1. **Repo root is `HeyInky/HeyInky`** (the folder with the git remote and `.env`). `/App`, `/proxy`,
   `/shared` live there. — That is where the GitHub repo and the `.env` the proxy must read are.

2. **XcodeGen; `.xcodeproj` is generated and git-ignored.** — Reproducible project, no `.pbxproj`
   merge conflicts between parallel agents; sources are folder globs so adding files needs no spec edit.

3. **Modules are folders compiled into the app target, not separate frameworks.** — Lets agents
   work in parallel with zero `public` boilerplate or target wiring. Boundaries are enforced by
   documented interfaces (module READMEs) and ownership in CLAUDE.md. Can be split into Swift
   packages later if build times demand it.

4. **Persistence: file-based JSON + `PKDrawing` per page (not SwiftData).** —
   `PKDrawing` and PDFs are blobs anyway; plain files are easy to inspect, diff, back up, sync
   (iCloud Drive later) and test with a temp root; no schema migrations; no Swift 6 concurrency
   friction with `ModelContext`. Layout: `Notebooks/<id>/notebook.json`, `pages/<pageID>.drawing`,
   `pages/<pageID>.inky.json`, `assets/`. Atomic writes; ink autosaves 800 ms after the last change.

5. **Page coordinate system = page points** (default 816×1056, US Letter at 96 dpi; PDF pages use
   their crop box size). `PKDrawing` uses these coordinates; Inky uses the same space normalized 0–1.

6. **The proxy is a thin pass-through of the OpenAI Responses API body.** The app builds the full
   request (prompt, images, schema); the proxy adds the key, allow-lists top-level fields, forces
   `store: false`, defaults `stream: true`, and pipes SSE back. — Swapping to "Sign in with ChatGPT"
   is then one new `InkyModelClient` that posts the same body straight to OpenAI. The handler uses
   only Fetch API types so the same code runs on Node and as a Cloudflare Worker.

7. **Prompt and schema live in `/shared` and are bundled into the app.** — One source of truth used
   by the app, the proxy smoke test and both test suites.

8. **Schema optional fields are `["T","null"]` and always required** (OpenAI strict mode). Swift
   models them as optionals. `$comment` was replaced with a root `description`.

9. **Schema text is sent verbatim, never re-serialized from a dictionary.** — Found while verifying
   the live path: Swift dictionaries shuffle keys; OpenAI strict outputs generate keys in schema
   order, so when `type` was not first in a def the model could not produce that action (asked to
   "highlight", it circled; sometimes it inserted empty graph cards). Guarded by tests on both sides.

10. **Model: `gpt-5.4-mini`, reasoning effort `low`.** — In this account it gave accurate regions
    (title highlight IoU ≈ 0.75–0.8) with ~1.5–3 s end-to-end latency. Bigger models (`gpt-5.4`,
    `gpt-5.5`) gave the same placements, slower. One constant: `InkyConfig.modelName`.

11. **Localization = page PNG with a light labeled 0.1 grid + recognized text lines with boxes**,
    plus a zoomed crop (finer grid, page-coordinate labels) when lassoed. Text comes from the PDF text
    layer when present and on-device Vision OCR for ink/images. — The text boxes give exact regions;
    the grid lets the model localize non-text things. All in `InkyLocalization` + `snapshotForInky`.

12. **Actions stream in incrementally.** The parser decodes each action as soon as its JSON object
    closes, so the first highlight can appear before the response finishes.

13. **Inky layer is a SwiftUI overlay above the canvas (sibling view), tracking scroll/zoom**;
    background (paper/PDF/images) and lasso ride inside the `PKCanvasView` content. — PencilKit's
    zoom only scales its own content view, `PKCanvasView` hides subviews from accessibility, and a
    sibling keeps annotation gestures (select/move/edit/cards) away from ink. A `PassthroughView`
    only claims touches that hit an annotation (or while something is selected).

14. **Annotation edits are stored as data**, not baked into the action: `offset` (move), `isHidden`,
    text edits rewrite the action's text field. Per-annotation hide/show + whole-layer toggle live in
    the toolbar's Inky menu; select → Edit / Hide / Delete on the page.

15. **Lasso is Inky's own**, not PencilKit's lasso (its selection isn't public API). While Inky is
    summoned, one-finger/pencil touches draw the lasso loop and ink is paused; two fingers scroll.

16. **Pencil squeeze always summons Inky** (anchored at the hover location when available). Double-tap
    follows the system preference (eraser toggle / previous tool / palette).

17. **Custom tool-picker item (iOS 18 `PKToolPickerCustomItem`)** for Inky; selecting it summons Inky,
    switching away dismisses. The picker is owned per notebook so tool choice survives page changes.

18. **Light mode only for v1** — paper is white and PencilKit inverts ink colors in dark mode.

19. **One accent color: ink indigo `#5B5BD6`.** Highlights keep their semantic marker colors.

20. **A sample "Lecture 7" PDF notebook is generated on first launch** — gives new users (and tests)
    something to ask Inky about immediately; its title box is known, so it doubles as the
    end-to-end accuracy fixture.

21. **Voice:** `SFSpeechRecognizer` with `requiresOnDeviceRecognition` when supported; TTS with
    `AVSpeechSynthesizer`; Markdown is stripped to plain text for speech.

22. **Tests:** Swift Testing for unit tests, XCTest for UI tests (mock client via launch argument).
    The live OpenAI test is opt-in (`TEST_RUNNER_INKY_LIVE=1`) to keep the default suite free/offline.

23. **Inky's motion is a pure function of (state, time)** (`InkyMotion`), drawn with `Canvas` inside a
    `TimelineView`. — Every frame is reproducible, so snapshot tests render fixed reference poses, state
    changes can be blended numerically, and Reduce Motion simply shows the reference pose.

24. **Inky performs annotations instead of them popping in.** Actions are still applied and persisted
    immediately; only the *display* is choreographed (`InkyChoreographer`: hidden until Inky lands,
    then revealed with the nib's progress). — Streaming, persistence and tests stay unchanged; leaving
    the page mid-performance just shows everything. Without an on-screen layer nothing is delayed.

25. **The nib path and the stroke-reveal share one progress value** (`InkyStroke.tip(at:)` ⇄ each
    mark's `progress`). — Ink always appears exactly under Inky's nib; one timing source.

26. **The `say()` reply waits until Inky has finished drawing.** — The toast ("Highlighted the
    title.") reads as Inky's sign-off together with the happy bounce instead of arriving first.

27. **Sounds are synthesized tones played as system sounds, on by default, with a toggle.** — No
    audio assets, tiny and quiet, mix with other audio and never reconfigure the `AVAudioSession`
    that speech input/output use. Haptics also go to Apple Pencil Pro via `UICanvasFeedbackGenerator`.

28. **App icon and launch image are rendered from SwiftUI** (`InkyArtwork.swift`) and tests fail if the
    committed PNGs drift. — One source of truth for Inky's look; re-render with one command.

29. **Image snapshots without a third-party library** (`SnapshotSupport.swift`): `ImageRenderer` →
    PNG next to the tests via `#filePath`, small per-pixel tolerance. — No package dependency in the
    XcodeGen spec; good enough for vector art rendered on the same simulator runtime.


30. **Integration (main):** module branches merged in order ai-core → chemistry → graphs → character; all
    interface requests fulfilled on main (see `INTERFACE_REQUESTS.md` status lines). Interplay of 26 with
    the AICore prompt ("`say` first"): the `say` arrives before any annotation is queued, so the toast
    shows immediately while Inky draws — faster feedback wins; a `say` that arrives mid-performance still waits.

31. **Schema v3 (graphs): oblique asymptotes (`slope`) and `xLabel`/`yLabel`.** New Swift fields are optionals
    defaulting to nil, so annotations saved before the change still decode. Graph expressions stay
    JavaScript for the model (the validator rejects `^`); the card's own parser accepts `^` for student edits.

32. **Cards keep child accessibility** (`.contain` instead of `.combine`) on the Inky layer, so VoiceOver and
    UI tests reach sliders, chips and menus inside molecule/graph cards.

33. **Inky teaches on the page; the sidebar is the exception.** Schema v3 adds `draw` (strokes + handwriting
    in normalized page space) and `addPage`. The prompt makes on-page work the default for "explain / solve /
    show / draw"; `openSidebar` is for explicit "notes / summarize / in words". — Students learn from watching
    the work happen where their notes are, not from a chat transcript.

34. **Inky's drawings are real PencilKit ink, rendered from geometry** (`DrawInk`), stored as Inky-layer
    annotations. — They look like the student's own ink, animate under Inky's nib from the same paths,
    stay hideable/undoable/selectable as Inky's, and "Make it my ink" turns them into user strokes.

35. **The model decides the chemistry and content; the app decides the geometry.** Text centering on bond
    ends, collision resolution (labels slide along their bond and the bond lengthens), snapping enclosures
    to the text they circle, label/note placement off other text and ink (`InkyLayout`), clean bond angles
    from the student's skeleton and a carbon valence check (`BondLayout`). — Language models are good at
    "which atoms get how many H's" and bad at pixel geometry; splitting it this way made drawings readable.

36. **The model sees the student's ink as geometry**: strokes simplified to corners (RDP) and junctions with
    bond counts. — Exact atom positions instead of estimating from the image; "4 − lines meeting" turns
    hydrogen counting into arithmetic.

37. **Adaptive reasoning effort**: `medium` for draw/solve/explain requests, `low` for quick marks. — Medium
    fixed hydrogen counting in testing; quick highlights keep ~2 s latency.

38. **Our own Select tool replaces PencilKit's lasso** (its selection isn't public API and can't include
    images or Inky's marks). Edits through it are whole-page snapshots for undo; the per-page `UndoManager`
    is shared by ink, Inky and selection edits.

39. **Pixel eraser by default.** PencilKit restores the palette's saved state over the items an app passes
    in, so a one-time migration clears the saved palette when our item set changes (`layoutVersion`).

40. **GoodNotes basics:** draw-and-hold shape correction (pure-geometry recognizer; the hold is detected
    from the pen-lift time because touches report no movement while still), typed text boxes as page
    content (drawn by `PageRenderer`, so thumbnails/export/Inky see them), handwriting → text via on-device
    Vision, PDF export with or without Inky's marks.
