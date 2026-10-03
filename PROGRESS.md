# Progress

_Last updated: 2026-10-03 (foundation session)._

## Status: foundation complete ✅
- App builds with **zero warnings** (Swift 6, strict concurrency) and runs on the iPad simulator.
- **Unit tests:** 49 Swift Testing tests green (schema decoding, schema⇄Swift sync, stream parsing,
  prompt builder, proxy client, mock client, store/persistence, PDF import + text extraction, image
  insert, renderers, Inky layer placement/move/hide, session apply/error paths, localization, markdown).
- **UI tests:** 3 XCUITests green (mock client): summon Inky → ask → highlight/circle/star/label/fillText
  + toast appear → select & delete one annotation; "explain" opens the sidebar with a play button;
  create notebook → draw → add page.
- **Proxy:** 14 Node tests green (handler, streaming server, token, error passthrough, strict-schema
  rules, `type`-first ordering, fixtures validate with Ajv). `npm run smoke` passes against real OpenAI.
- **Live end-to-end** (`LiveProxyIntegrationTests`, opt-in): the real app pipeline renders the sample
  lecture page, sends it through the proxy, and "highlight the title of this page" lands on the title
  (IoU 0.75–0.79 vs. the true title box) in ~1.5–3 s.

## What's built
| Area | Done |
|---|---|
| Project | XcodeGen `App/project.yml`; app + unit + UI test targets; module folders globbed in |
| Library | Notebook grid with live thumbnails, new notebook (blank/lined/grid/dotted), import PDF as notebook, rename/delete, sample notebook on first launch |
| Notebook | PencilKit canvas with zoom, tool picker, undo/redo, page strip, prev/next, add page (paper styles), delete page, import PDF into notebook, insert image (Photos/Files) with move/resize/delete, autosave (debounced + on background/page switch) |
| Inky summon | Floating Inky button, Pencil Pro squeeze (anchored at hover), custom Inky tool-picker item, lasso a region for context, minimal ask popover (text + on-device voice), thinking state, cancel |
| AI | `InkyModelClient` protocol, `ProxyInkyModelClient` (SSE, incremental actions), `MockInkyModelClient`, prompt builder, grid-overlay localization + PDF text + Vision OCR |
| Inky layer | Renderers for highlight, circle, star, label (+arrow), fillText (handwriting font); stub cards for molecule/graph; select → edit / hide / delete; drag to move; layer menu with per-annotation visibility and clear; persisted per page |
| Replies | `say` toast; `openSidebar` Markdown explainer with play/pause TTS |
| Proxy | Node/TS server + Worker entry, `.env` loading, optional shared token, field allow-list, `store:false` |

## InkyCharacter (feat/character) ✅
- **Inky** is an original vector pen character (Canvas): ink-drop cowlick, big eyes, nib. States:
  idle, listening, thinking, speaking, happy, hopping, writing — each with its own motion; state
  changes blend; Reduce Motion holds reference poses and cross-fades.
- **Acting on the page:** for each annotation Inky drops/hops (parabolic arc, squash & stretch,
  shadow) to where it goes, draws it with a stroke-reveal under its nib (highlight swipe, circle loop,
  star outline → fill, label text → arrow, handwriting, card pop), then a happy bounce, the reply
  toast, and Inky hops away. Reduce Motion: annotations fade in one by one.
- **Polish:** ask popover, floating button (ink-drop "seat" while Inky is out), toasts, sidebar;
  haptics (incl. Apple Pencil Pro); subtle synthesized sounds with an "Inky Sounds" toggle.
- **App icon + launch screen** featuring Inky, rendered from SwiftUI art.
- **Tests:** 72 unit tests (character snapshots per state + small sizes, choreography, artwork sync),
  4 UI tests incl. `InkyChoreographyUITests` (hop-to-target order, annotation hidden until Inky
  arrives, nib on the target, celebrate, reply, leave). All green; zero warnings.
- Shell touch-points are listed in `INTERFACE_REQUESTS.md`.

### Screen recording: Inky in action
1. Build & install on a simulator (or device): `xcodebuild build … -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'`
   (or run from Xcode with the launch arguments below in the scheme).
2. Launch with the mock client and slightly slower motion so it reads well on video:
   `xcrun simctl launch booted com.heyinky.app -InkyUITestReset YES -InkyUseMockClient YES -InkyMotionScale 1.5`
   (drop `-InkyMotionScale` for real speed; use the proxy instead of the mock for a real answer).
3. Start recording: `xcrun simctl io booted recordVideo --codec h264 inky.mp4`
   (on device: Control Center → Screen Recording).
4. Open **Welcome to Hey Inky**, tap Inky (bottom right), type **highlight the title**, send.
   Inky drops onto the title, swipes the highlight, hops to the circle, star, label and answer
   text, bounces, and the reply toast appears.
5. Tap Inky again, ask **explain this page** → sidebar opens; tap **Listen** (Inky talks).
6. Tap the mic in the ask popover to show the listening pose (needs mic permission).
7. Optional: Settings → Accessibility → Motion → Reduce Motion on, repeat step 4 (annotations fade in).
8. Stop recording with Ctrl-C.

## Known gaps / follow-ups for the lead
- Simulator can't test real Pencil squeeze / hover; verify on device (`-InkyProxyURL http://<mac-ip>:8787`,
  proxy with `INKY_PROXY_HOST=0.0.0.0`).
- PDF pages with rotation: rendered correctly, but text-layer boxes are skipped (OCR covers them).
- One page on screen at a time (no continuous vertical scroll yet).
- Annotations don't scale with the page if a page's size changes (not currently possible).
- No iCloud sync, search, or export yet.

## Next steps per module agent
- **AICore** (`App/Modules/AICore/README.md`): "Sign in with ChatGPT" client (one file + factory switch),
  follow-up turns/conversation memory, an IoU eval set for localization tuning, image cost/latency tuning.
- **Chemistry** (`App/Modules/Chemistry/README.md`): replace `MoleculeCardView` stub with bundled RDKit.js
  rendering + SMARTS highlight/star, Ketcher editing, offline assets, tests.
- **Graphs** (`App/Modules/Graphs/README.md`): replace `GraphCardView` stub with bundled JSXGraph,
  sliders/draggable points, safe expression compilation, persist interactive state, tests.
- **InkyCharacter** (`App/Modules/InkyCharacter/README.md`): done; next: hop back to the floating
  button (needs its page-space position, see `INTERFACE_REQUESTS.md`), Pencil Pro haptics at hover.
