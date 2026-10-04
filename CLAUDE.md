# Hey Inky — guide for agents

AI-native handwritten notes for iPad (STEM students). Notebooks + Apple Pencil ink + PDFs,
and **Inky**, an AI pen that answers by *acting on the page* (highlight, circle, star, label,
fill text, insert molecule/graph cards) or with a sidebar explainer read aloud.

## Layout
```
/App                    iPadOS app (SwiftUI + UIKit/PencilKit), Swift 6, iPadOS 18+
  project.yml           XcodeGen spec → HeyInky.xcodeproj (generated, git-ignored)
  HeyInky/              app shell (owned by the foundation/lead agent)
    App/                entry point, AppModel (store + client), SampleContent
    Model/              Notebook/Page/InkyAnnotation, NotebookStore (file persistence)
    Library/            notebook grid, thumbnails
    Notebook/           NotebookView (toolbar, page strip, Inky overlays), InkyLayerMenu
    Page/               PageCanvasController (PKCanvasView + layers), PageEditorModel,
                        PageRenderer, InkyToolPickerHost (tool picker + Inky item)
    Inky/               InkySession (summon→ask→stream→apply), ask card, toast, sidebar,
                        SpeechInput (on-device STT), SpeechOutput (TTS), MarkdownText
    InkyLayer/          renderers for page annotations + geometry + selection/edit
    Design/Theme.swift  design tokens (one accent color)
  Modules/              parallel-agent modules (compiled into the app target)
    AICore/             InkyAction contract, InkyModelClient, proxy/mock clients, localization
    Chemistry/          MoleculeCardView (stub → RDKit.js/Ketcher)
    Graphs/             GraphCardView (stub → JSXGraph)
    InkyCharacter/      InkyCharacterView (placeholder art)
  HeyInkyTests/         Swift Testing unit tests
  HeyInkyUITests/       XCUITest (mock client)
/proxy                  Node 22+ TypeScript proxy (also a Cloudflare Worker entry)
/shared                 inky_actions.schema.json (THE contract), inky_system_prompt.md, fixtures/
DECISIONS.md            why things are the way they are
PROGRESS.md             status + next steps per module
```

## Module ownership
| Area | Owner | Contract you must keep |
|---|---|---|
| App shell, persistence, canvas, Inky layer, session | lead | — |
| `Modules/AICore` | AI agent | `InkyModelClient`, `InkyRequest`, `InkyStreamEvent`, `InkyLocalization.modelImages` |
| `Modules/Chemistry` | chemistry agent | `MoleculeCardView(action: InsertMoleculeCardAction)` |
| `Modules/Graphs` | graphs agent | `GraphCardView(action: InsertGraphCardAction)` |
| `Modules/InkyCharacter` | character agent | `InkyCharacterView(state:size:)`, `InkyCharacterState` |
| `/proxy` | AI agent | `POST /inky` = Responses API body in, SSE out; `GET /health` |
| `/shared` | lead + AI agent | edit schema ⇒ update Swift types + fixtures; both test suites must pass |

Each module folder has a README with its interface and next steps. Stay inside your module;
if you need a change in the shell, keep it minimal and mention it in your PR/commit.

## Core architecture
- **InkyAction contract**: `/shared/inky_actions.schema.json` (OpenAI strict structured outputs)
  ⇄ `Modules/AICore/Contract/InkyAction.swift`. Coordinates are normalized page space
  (0,0 top-left … 1,1 bottom-right). `InkyActionSchemaSyncTests` + proxy `schema.test.ts` catch drift.
- **Schema key order matters**: strict outputs generate keys in schema order. The schema text is
  spliced into the request verbatim (`InkyPromptBuilder.bodyData`). Never round-trip it through a
  Swift dictionary; keep `type` the first property of every action.
- **Model access** only via `InkyModelClient` (`InkyClientFactory.makeDefault()`); model name is
  `InkyConfig.modelName`. The app never contains an API key; the proxy reads `OpenAI_API_Key`
  from the repo-root `.env`.
- **Localization**: `InkyLocalization.modelImages` renders the page with a light labeled grid
  (+ zoomed crop when lassoed); `PageEditorModel.snapshotForInky` adds PDF text lines and Vision OCR
  with normalized boxes.
- **Page view**: `PKCanvasView` scrolls/zooms; `PageBackgroundView` (paper/PDF/images) and the
  lasso view ride inside its content; the Inky layer (SwiftUI in a `PassthroughView`) is a sibling
  above it whose frame tracks scroll/zoom. Touches reach the Inky layer only on annotations
  (`PageEditorModel.overlayWantsTouch`), everything else goes to PencilKit.
- **Persistence**: JSON + `PKDrawing` files per notebook (see `NotebookStore` header). Ink autosaves
  800 ms after the last stroke and on page change/background.

### Precision: perceive → reason → place
- `HeyInky/Perception`: `LineArt` (raster → polylines), `StructureRecognizer` (bond graph), `AtomLabelReader`
  (O/OH/NH… from shape + Vision), `PageStructureFinder` (images, ink, PDF → `PageStructure` S1… with atom ids,
  SMILES and hidden H's via RDKit `fromGraph`). Sent to the model in the context packet.
- The model marks structures by id with `annotateStructure`; `StructureAnnotator` computes exact geometry and
  emits ordinary `draw`/`label` actions (`addAnnotation(exact: true)`).
- New figures: `insertChemScheme` (`ChemSchemeView`/`ChemSchemeLayout`, RDKit `scheme`) and `insertDiagram`
  (`HeyInky/Figures`: `DiagramEngine` sanitizes/styles/checks SVG → vector PDF). `FigurePreparer` measures and
  places them in free space; `InkyDeepChecker` rejects bad ones before they reach the page (one retry).
- Never ask the model for geometry the app can compute. New annotation kinds that attach to page content
  should follow the same pattern: perceive it, give it ids, compile the marks in code.

## Build & test from the CLI
```bash
brew install xcodegen                 # once
cd App && xcodegen generate           # after adding/removing files or editing project.yml

# Build
xcodebuild build -project App/HeyInky.xcodeproj -scheme HeyInky \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -derivedDataPath App/build/DerivedData

# All tests (unit + UI; UI tests use the mock client, no network)
xcodebuild test -project App/HeyInky.xcodeproj -scheme HeyInky \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -derivedDataPath App/build/DerivedData

# Only unit tests:  add -only-testing:HeyInkyTests
# Live end-to-end through the real proxy + OpenAI (costs a little; proxy must be running):
TEST_RUNNER_INKY_LIVE=1 xcodebuild test ... -only-testing:HeyInkyTests/LiveProxyIntegrationTests

# Proxy
cd proxy && npm install && npm run check   # typecheck + unit tests
npm start                                  # http://127.0.0.1:8787  (reads ../.env)
npm run smoke                              # real OpenAI round trip through the running proxy
```
Pick any iPad simulator from `xcrun simctl list devices available`. If tests fail with
"Application failed preflight checks / Busy", the simulator is wedged: `xcrun simctl shutdown all`
and `xcrun simctl erase <udid>`.

### Launch arguments
`-InkyUseMockClient YES` (canned answers) · `-InkyUITestReset YES` (fresh temp library + sample)
· `-InkyProxyURL http://<mac-ip>:8787` (device → Mac; start proxy with `INKY_PROXY_HOST=0.0.0.0`)
· `-InkyProxyToken <t>` (if `INKY_PROXY_TOKEN` is set in `.env`) · `-InkySkipSample YES`.
DEBUG-only QA seeding (`UITestScenarios`): `-InkyUITestScenario molecule,asymptotes,worksheet`
· `-InkyUITestImage <png>` · `-InkyUITestLibrary <name>` (survives relaunch) · `-InkyUITestSpeech "<text>"`.
Live end-to-end UI flows: `TEST_RUNNER_INKY_LIVE=1 [TEST_RUNNER_INKY_MODEL=…] … -only-testing:HeyInkyUITests/EndToEndUITests`.

## Conventions
- Swift 6 strict concurrency, zero warnings. UI/model types are `@MainActor`; `@Observable` for state.
  Callbacks from audio/speech/system queues are built in `nonisolated static` functions (see
  `SpeechInput`) so they don't inherit main-actor isolation.
- New files are picked up by folder globs; just run `xcodegen generate`.
- Design: calm and minimal. Use `Theme` tokens, `inkySurface()`, one accent color, generous spacing,
  SF Rounded for Inky's voice. Light mode only for v1.
- Accessibility identifiers: `inky.*`, `page.*`, `notebook.*`, `library.*`. Container views that
  carry an identifier must use `.accessibilityElement(children: .contain)` or they hide their children.
- Tests: Swift Testing (`@Test`) for unit tests, XCTest for UI tests. Shared JSON fixtures live in
  `/shared/fixtures` and are used by both Swift and proxy tests.
- Never commit `.env`. Commit and push to `main` after each working milestone.
